#!/usr/bin/env bash
set -uo pipefail

LEADER="http://$STATEFULSET.$VAULT_NAMESPACE.svc:8200"
node() { echo "http://$STATEFULSET-$1.$SERVICE.$VAULT_NAMESPACE.svc:8200"; }
key() { kubectl -n "$VAULT_NAMESPACE" get secret "$KEYS_SECRET" -o "jsonpath={.data.$1}" 2>/dev/null | base64 -d; }
v() { curl -sS -f -m 30 -H "X-Vault-Token: $ROOT_TOKEN" "$@"; }
policy() { v -X PUT "$LEADER/v1/sys/policies/acl/$1" -d "$(jq -n --arg p "$2" '{policy: $p}')" >/dev/null; }
mounted() { jq -e --arg m "$2/" '.data[$m]' <<<"$1" >/dev/null; }

initialize() {
  local status out
  status=$(curl -sS -f -m 10 "$(node 0)/v1/sys/init" | jq -r .initialized) || return 1
  [ "$status" = true ] && return 0
  out=$(curl -sS -f -m 60 -X PUT "$(node 0)/v1/sys/init" -d '{"secret_shares":1,"secret_threshold":1}') || return 1
  until kubectl -n "$VAULT_NAMESPACE" create secret generic "$KEYS_SECRET" \
    --from-literal=unseal-key="$(jq -r '.keys_base64[0]' <<<"$out")" \
    --from-literal=root-token="$(jq -r .root_token <<<"$out")" >/dev/null; do
    sleep 5
  done
  echo "initialized $STATEFULSET-0, keys in $VAULT_NAMESPACE/$KEYS_SECRET"
}

unseal() {
  local i sealed
  for i in $(seq 0 $((REPLICAS - 1))); do
    sealed=$(curl -sS -f -m 10 "$(node "$i")/v1/sys/seal-status" 2>/dev/null | jq -r .sealed)
    [ "$sealed" = true ] || continue
    curl -sS -f -m 60 -X PUT "$(node "$i")/v1/sys/unseal" -d "$(jq -n --arg k "$UNSEAL_KEY" '{key: $k}')" >/dev/null \
      && echo "unsealed $STATEFULSET-$i"
  done
}

nico_token() {
  local token accessor out
  token=$(kubectl -n "$NICO_NAMESPACE" get secret "$NICO_TOKEN_SECRET" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d)
  if [ -n "$token" ] && accessor=$(v -X POST "$LEADER/v1/auth/token/lookup" -d "$(jq -n --arg t "$token" '{token: $t}')" | jq -er .data.accessor); then
    v -X POST "$LEADER/v1/auth/token/renew-accessor" -d "$(jq -n --arg a "$accessor" '{accessor: $a}')" >/dev/null
    return
  fi
  out=$(v -X POST "$LEADER/v1/auth/token/create-orphan" -d '{"policies": ["nico-app"], "period": "768h"}') || return 1
  kubectl -n "$NICO_NAMESPACE" create secret generic "$NICO_TOKEN_SECRET" --from-literal=token="$(jq -r .auth.client_token <<<"$out")" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null || return 1
  echo "stored $NICO_NAMESPACE/$NICO_TOKEN_SECRET"
}

configure() {
  local mounts auths
  mounts=$(v "$LEADER/v1/sys/mounts") || return 1
  mounted "$mounts" "$KV_MOUNT" || v -X POST "$LEADER/v1/sys/mounts/$KV_MOUNT" -d '{"type": "kv", "options": {"version": "2"}}' >/dev/null || return 1
  mounted "$mounts" "$PKI_MOUNT" || v -X POST "$LEADER/v1/sys/mounts/$PKI_MOUNT" -d '{"type": "pki", "config": {"max_lease_ttl": "87600h"}}' >/dev/null || return 1
  if [ -z "$(curl -sS -f -m 10 "$LEADER/v1/$PKI_MOUNT/ca/pem")" ]; then
    v -X POST "$LEADER/v1/$PKI_MOUNT/root/generate/internal" -d "$(jq -n --arg cn "$PKI_COMMON_NAME" '{common_name: $cn, ttl: "87600h"}')" >/dev/null || return 1
  fi
  v -X POST "$LEADER/v1/$PKI_MOUNT/roles/$PKI_ROLE" -d '{"allow_any_name": true, "enforce_hostnames": false, "allow_ip_sans": true,
    "allowed_uri_sans": "spiffe://*", "require_cn": false, "use_csr_common_name": true, "use_csr_sans": true, "key_type": "any", "max_ttl": "8760h"}' >/dev/null || return 1

  auths=$(v "$LEADER/v1/sys/auth") || return 1
  mounted "$auths" "$AUTH_MOUNT" || v -X POST "$LEADER/v1/sys/auth/$AUTH_MOUNT" -d '{"type": "kubernetes"}' >/dev/null || return 1
  v -X POST "$LEADER/v1/auth/$AUTH_MOUNT/config" -d '{"kubernetes_host": "https://kubernetes.default.svc"}' >/dev/null || return 1
  policy cert-manager "path \"$PKI_MOUNT/sign/$PKI_ROLE\" { capabilities = [\"create\", \"update\"] }" || return 1
  v -X POST "$LEADER/v1/auth/$AUTH_MOUNT/role/$CERT_MANAGER_ROLE" -d "$(jq -n --arg sa "$CERT_MANAGER_SERVICE_ACCOUNT" --arg ns "$CERT_MANAGER_NAMESPACE" \
    '{bound_service_account_names: $sa, bound_service_account_namespaces: $ns, token_policies: "cert-manager", ttl: "1h"}')" >/dev/null || return 1

  policy nico-app "$(cat <<POLICY
path "$KV_MOUNT/data/machines/*"     { capabilities = ["create", "read", "update", "patch", "delete", "list"] }
path "$KV_MOUNT/metadata/machines/*" { capabilities = ["read", "list", "delete"] }
path "$KV_MOUNT/data/nico/*"         { capabilities = ["read", "list"] }
path "$PKI_MOUNT/sign/$PKI_ROLE"     { capabilities = ["create", "update"] }
path "$PKI_MOUNT/issue/$PKI_ROLE"    { capabilities = ["create", "update"] }
path "$PKI_MOUNT/cert/ca"            { capabilities = ["read"] }
POLICY
)" || return 1
  nico_token
}

configured=0
while true; do
  kubectl -n "$VAULT_NAMESPACE" get secret "$KEYS_SECRET" >/dev/null 2>&1 || initialize
  UNSEAL_KEY=$(key unseal-key)
  ROOT_TOKEN=$(key root-token)
  if [ -n "$UNSEAL_KEY" ]; then
    unseal
    if [ ! -f /tmp/ready ] || [ $((SECONDS - configured)) -ge 3600 ]; then
      configure && configured=$SECONDS && touch /tmp/ready
    fi
  fi
  sleep "$INTERVAL"
done

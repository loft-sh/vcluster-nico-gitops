#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: VAULT_ADDR=<url> VAULT_TOKEN=<admin token> scripts/bootstrap-vault-operator.sh --context <kube-context>
         [--prefix nico] [--auth-mount <prefix>/kubernetes] [--kubernetes-host <url>]

Run once per site, after the vault-config layer has installed the Vault Config Operator.
Enables Kubernetes auth for the cluster, gives the operator a policy over the prefix only,
and proves the operator can log in. The admin token is used only here and never printed.

  --prefix            Vault path the operator manages (default nico)
  --auth-mount        Kubernetes auth mount for this cluster (default <prefix>/kubernetes)
  --kubernetes-host   API server address as Vault reaches it. Sets the mount's config even if
                      it exists. Default: the context's server, used only for a new mount
  --namespace         operator namespace (default vault-config-operator)
  --wait              seconds to wait for the operator to be installed (default 900)
EOF
  exit 2
}

CONTEXT="" PREFIX=nico AUTH="" HOST="" NS=vault-config-operator WAIT=900
SA=vault-config-operator-controller-manager ROLE=vault-config-operator
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CONTEXT=$2; shift 2 ;;
    --prefix) PREFIX=${2%/}; shift 2 ;;
    --auth-mount) AUTH=${2%/}; shift 2 ;;
    --kubernetes-host) HOST=$2; shift 2 ;;
    --namespace) NS=$2; shift 2 ;;
    --wait) WAIT=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$CONTEXT" ] || usage
: "${VAULT_ADDR:?set VAULT_ADDR}" "${VAULT_TOKEN:?set VAULT_TOKEN to a Vault admin token}"
AUTH=${AUTH:-$PREFIX/kubernetes}
POLICY=${PREFIX//\//-}-vault-config-operator

k() { kubectl --context "$CONTEXT" "$@"; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
umask 077
printf 'X-Vault-Token: %s\n' "$VAULT_TOKEN" >"$WORK/admin"
unset VAULT_TOKEN

call() {
  local method=$1 path=$2 body=${3:-} auth=${4-$WORK/admin} args=()
  [ -n "$auth" ] && args+=(-H "@$auth")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data-binary "@-")
  printf '%s' "$body" | curl -sS -o "$WORK/out" -w '%{http_code}' -X "$method" "${args[@]}" "$VAULT_ADDR/v1/$path"
}
must() {
  local code
  code=$(call "$@")
  case "$code" in 2*) ;; *) echo "Vault $1 $2 returned $code: $(jq -r '.errors // [] | join("; ")' "$WORK/out" 2>/dev/null)" >&2; exit 1 ;; esac
}

code=$(curl -sS -o /dev/null -w '%{http_code}' "$VAULT_ADDR/v1/sys/health" || true)
case "$code" in 200|429|472|473) ;; *) echo "Vault at $VAULT_ADDR is not ready (health $code)" >&2; exit 1 ;; esac
must GET auth/token/lookup-self

echo "waiting for the Vault Config Operator in $NS"
end=$((SECONDS + WAIT))
delegated() {
  k get clusterrolebindings -o json | jq -e --arg sa "$SA" --arg ns "$NS" \
    '[.items[] | select(.roleRef.name == "system:auth-delegator") | .subjects[]? | select(.kind == "ServiceAccount" and .name == $sa and .namespace == $ns)] | length > 0' >/dev/null
}
until k -n "$NS" get serviceaccount "$SA" >/dev/null 2>&1 && delegated; do
  [ $SECONDS -lt $end ] || { echo "the vault-config layer has not installed the operator and its auth-delegator binding yet" >&2; exit 1; }
  sleep 10
done

must GET sys/auth
NEW=false
if ! jq -e --arg m "$AUTH/" '.data[$m] // .[$m]' "$WORK/out" >/dev/null; then
  must POST "sys/auth/$AUTH" '{"type": "kubernetes", "description": "Kubernetes auth for this cluster"}'
  NEW=true
  echo "enabled Kubernetes auth at $AUTH"
fi
if [ "$NEW" = true ] || [ -n "$HOST" ]; then
  HOST=${HOST:-$(k config view --minify -o jsonpath='{.clusters[0].cluster.server}')}
  CA=$(k -n kube-system get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}')
  must POST "auth/$AUTH/config" "$(jq -n --arg h "$HOST" --arg ca "$CA" \
    '{kubernetes_host: $h, kubernetes_ca_cert: $ca, disable_local_ca_jwt: true}')"
  echo "configured $AUTH for $HOST"
fi

PP=${PREFIX//\//-}
RULES=$(cat <<EOF
path "$PREFIX/*"                 { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/mounts"                { capabilities = ["read"] }
path "sys/mounts/$PREFIX/*"      { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/auth"                  { capabilities = ["read"] }
path "sys/auth/$PREFIX/*"        { capabilities = ["create", "read", "update", "delete", "sudo"] }
path "auth/$PREFIX/*"            { capabilities = ["create", "read", "update", "delete", "list", "sudo"] }
path "sys/policies/acl"          { capabilities = ["list"] }
path "sys/policies/acl/$PP-*"    { capabilities = ["create", "read", "update", "delete", "list"] }
EOF
)
case "$AUTH/" in
  "$PREFIX"/*) ;;
  *) RULES="$RULES
path \"auth/$AUTH/role/*\"     { capabilities = [\"create\", \"read\", \"update\", \"delete\", \"list\"] }" ;;
esac
must PUT "sys/policies/acl/$POLICY" "$(jq -n --arg p "$RULES" '{policy: $p}')"
must POST "auth/$AUTH/role/$ROLE" "$(jq -n --arg sa "$SA" --arg ns "$NS" --arg p "$POLICY" \
  '{bound_service_account_names: [$sa], bound_service_account_namespaces: [$ns], token_policies: [$p], token_ttl: "1h", token_max_ttl: "4h"}')"
echo "wrote policy $POLICY and role $AUTH/role/$ROLE"

JWT=$(k -n "$NS" create token "$SA" --duration=10m)
must POST "auth/$AUTH/login" "$(jq -n --arg j "$JWT" --arg r "$ROLE" '{jwt: $j, role: $r}')" ""
jq -e --arg p "$POLICY" '.auth.token_policies | index($p)' "$WORK/out" >/dev/null \
  || { echo "the operator logged in but its token lacks $POLICY" >&2; exit 1; }
printf 'X-Vault-Token: %s\n' "$(jq -r .auth.client_token "$WORK/out")" >"$WORK/operator"
must POST auth/token/revoke-self "" "$WORK/operator"
echo "the operator logged in at $AUTH with $POLICY"

k -n "$NS" rollout restart deployment >/dev/null
echo "restarted the operator so it retries now"

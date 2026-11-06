#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: test/e2e/vault-config.sh --context <site> [--global-context <global>] [--jwt]" >&2; exit 2; }
CTX="" GLOBAL="" JWT=false
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CTX=$2; shift 2 ;;
    --global-context) GLOBAL=$2; shift 2 ;;
    --jwt) JWT=true; shift ;;
    *) usage ;;
  esac
done
[ -n "$CTX" ] || usage
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
k() { kubectl --context "$CTX" "$@"; }

k -n vault port-forward svc/vault 18200:8200 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
export VAULT_ADDR=http://127.0.0.1:18200
for _ in $(seq 60); do curl -sf "$VAULT_ADDR/v1/sys/health" >/dev/null && break; sleep 2; done

VAULT_TOKEN=root "$ROOT/scripts/bootstrap-vault-operator.sh" --context "$CTX" --kubernetes-host https://kubernetes.default.svc
"$ROOT/scripts/mint-nico-vault-token.sh" --context "$CTX"

echo "waiting for the operator to set up Vault"
k -n vault-config-operator wait --for=condition=ReconcileSuccessful --timeout=15m --all \
  secretenginemounts.redhatcop.redhat.io,authenginemounts.redhatcop.redhat.io,pkisecretengineconfigs.redhatcop.redhat.io,pkisecretengineroles.redhatcop.redhat.io,policies.redhatcop.redhat.io,kubernetesauthengineroles.redhatcop.redhat.io,approleauthengineroles.redhatcop.redhat.io >/dev/null
for c in $(k -n nico-system get certificates.cert-manager.io -o json 2>/dev/null | jq -r '.items[] | select(.status.lastFailureTime) | .metadata.name'); do
  k -n nico-system get certificates.cert-manager.io "$c" -o json | jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.status.conditions = [.status.conditions[]? | select(.type != "Issuing")] + [{type: "Issuing", status: "True", reason: "ManuallyTriggered", message: "retried after Vault was set up", lastTransitionTime: $t, observedGeneration: .metadata.generation}]' \
    | k replace --subresource=status -f - >/dev/null
  echo "retried certificate nico-system/$c"
done

root() { curl -sS -H 'X-Vault-Token: root' "$@"; }
login() {
  curl -sS -X POST "$VAULT_ADDR/v1/auth/$1/login" -d "$(jq -n --arg j "$2" --arg r "$3" '{jwt: $j, role: $r}')"
}

if [ -n "$GLOBAL" ]; then
  echo "checking the global cluster's login"
  for ns in nico-rest temporal; do
    kubectl --context "$GLOBAL" -n "$ns" create serviceaccount vault-secrets --dry-run=client -o yaml | kubectl --context "$GLOBAL" apply -f - >/dev/null
    kubectl --context "$GLOBAL" create clusterrolebinding "$ns-vault-secrets-vault-auth" --clusterrole=system:auth-delegator \
      --serviceaccount="$ns:vault-secrets" --dry-run=client -o yaml | kubectl --context "$GLOBAL" apply -f - >/dev/null
  done
  for _ in $(seq 60); do
    [ "$(root -o /dev/null -w '%{http_code}' "$VAULT_ADDR/v1/auth/nico/kubernetes-global/role/temporal-db")" = 200 ] && break
    sleep 5
  done
  for ns in nico-rest temporal; do
    T=$(login nico/kubernetes-global "$(kubectl --context "$GLOBAL" -n "$ns" create token vault-secrets)" "$ns-db" | jq -r '.auth.client_token // empty')
    [ -n "$T" ] || { echo "the global $ns service account could not log in" >&2; exit 1; }
    curl -sSf -H "X-Vault-Token: $T" -X POST "$VAULT_ADDR/v1/nico/kv/data/$ns/db" -d '{"data": {"check": "ok"}}' >/dev/null
    curl -sSf -H "X-Vault-Token: $T" "$VAULT_ADDR/v1/nico/kv/data/$ns/db" | jq -e '.data.data.check == "ok"' >/dev/null
    if curl -sf -H "X-Vault-Token: $T" "$VAULT_ADDR/v1/nico/kv/data/machines/x" >/dev/null; then
      echo "the global $ns role can read NICo's machine secrets" >&2; exit 1
    fi
    echo "global $ns logs in and reaches only its own path"
  done
fi

if [ "$JWT" = true ]; then
  echo "checking the operator logs in through JWT auth, as it would with HCP Vault"
  SA=vault-config-operator-controller-manager
  JWKS=$(k get --raw /openid/v1/jwks)
  ISSUER=$(k get --raw /.well-known/openid-configuration | jq -r .issuer)
  AUD=$(k -n vault-config-operator create token "$SA" --duration=10m | python3 -Ic 'import base64, json, sys
p = sys.stdin.read().split(".")[1]
print(json.dumps(json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))["aud"]))')
  KEYS=$(python3 -I - "$JWKS" <<'PY'
import base64, json, sys
def b64u(s): return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
def length(n): return bytes([n]) if n < 128 else bytes([0x80 | ((n.bit_length() + 7) // 8)]) + n.to_bytes((n.bit_length() + 7) // 8, "big")
def tlv(t, v): return bytes([t]) + length(len(v)) + v
def integer(b):
    b = b.lstrip(b"\0")
    return tlv(2, b"\0" + b if b[0] & 0x80 else b)
pems = []
for key in json.loads(sys.argv[1])["keys"]:
    if key["kty"] != "RSA":
        continue
    rsa = tlv(0x30, integer(b64u(key["n"])) + integer(b64u(key["e"])))
    spki = tlv(0x30, tlv(0x30, bytes.fromhex("06092a864886f70d0101010500")) + tlv(3, b"\0" + rsa))
    body = base64.b64encode(spki).decode()
    pems.append("-----BEGIN PUBLIC KEY-----\n" + "\n".join(body[i:i + 64] for i in range(0, len(body), 64)) + "\n-----END PUBLIC KEY-----")
print(json.dumps(pems))
PY
)
  root -X POST "$VAULT_ADDR/v1/sys/auth/nico/jwt" -d '{"type": "jwt"}' >/dev/null
  root -X POST "$VAULT_ADDR/v1/auth/nico/jwt/config" -d "$(jq -n --argjson k "$KEYS" --arg i "$ISSUER" '{jwt_validation_pubkeys: $k, bound_issuer: $i}')" >/dev/null
  root -X POST "$VAULT_ADDR/v1/auth/nico/jwt/role/vault-config-operator" -d "$(jq -n --argjson a "$AUD" \
    --arg s "system:serviceaccount:vault-config-operator:$SA" \
    '{role_type: "jwt", user_claim: "sub", bound_subject: $s, bound_audiences: $a, token_policies: ["nico-vault-config-operator"], token_ttl: "1h"}')" >/dev/null
  k apply -f - >/dev/null <<YAML
apiVersion: redhatcop.redhat.io/v1alpha1
kind: Policy
metadata:
  name: nico-jwt-check
  namespace: vault-config-operator
spec:
  authentication:
    path: nico/jwt
    role: vault-config-operator
    serviceAccount:
      name: $SA
  type: acl
  name: nico-jwt-check
  policy: |
    path "nico/kv/data/jwt-check" { capabilities = ["read"] }
YAML
  k -n vault-config-operator wait policies.redhatcop.redhat.io/nico-jwt-check --for=condition=ReconcileSuccessful --timeout=300s
  root -sf "$VAULT_ADDR/v1/sys/policies/acl/nico-jwt-check" >/dev/null
  k -n vault-config-operator delete policies.redhatcop.redhat.io/nico-jwt-check --wait=true >/dev/null
  echo "the operator logged in through JWT auth and wrote a policy"
fi

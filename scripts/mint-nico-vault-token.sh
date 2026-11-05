#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: VAULT_ADDR=<url> scripts/mint-nico-vault-token.sh --context <kube-context>
         [--prefix nico] [--auth-mount <prefix>/kubernetes] [--approle-mount <prefix>/approle] [--rotate]

Mints NICo's static Vault token from the AppRole the vault-config layer creates, and stores it
in nico-system/nico-vault-token. It logs in as the Vault Config Operator, so no admin token is
needed. The token is never printed. An existing token is kept unless --rotate is given; then
nico-api restarts on the new token and the old one is revoked.

  --wait   seconds to wait for the operator to create the AppRole (default 600)
EOF
  exit 2
}

CONTEXT="" PREFIX=nico AUTH="" APPROLE="" ROTATE=false WAIT=600
NS=vault-config-operator SA=vault-config-operator-controller-manager ROLE=vault-config-operator
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CONTEXT=$2; shift 2 ;;
    --prefix) PREFIX=${2%/}; shift 2 ;;
    --auth-mount) AUTH=${2%/}; shift 2 ;;
    --approle-mount) APPROLE=${2%/}; shift 2 ;;
    --rotate) ROTATE=true; shift ;;
    --wait) WAIT=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$CONTEXT" ] || usage
: "${VAULT_ADDR:?set VAULT_ADDR}"
AUTH=${AUTH:-$PREFIX/kubernetes}
APPROLE=${APPROLE:-$PREFIX/approle}
POLICY=${PREFIX//\//-}-nico-app

k() { kubectl --context "$CONTEXT" "$@"; }
if k -n nico-system get secret nico-vault-token >/dev/null 2>&1 && [ "$ROTATE" = false ]; then
  echo "nico-system/nico-vault-token exists, keeping it (use --rotate to replace it)"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
umask 077
call() {
  local method=$1 path=$2 body=${3:-} auth=${4-} args=()
  [ -n "$auth" ] && args+=(-H "@$auth")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data-binary "@-")
  printf '%s' "$body" | curl -sS -o "$WORK/out" -w '%{http_code}' -X "$method" "${args[@]}" "$VAULT_ADDR/v1/$path"
}
must() {
  local code
  code=$(call "$@")
  case "$code" in 2*) ;; *) echo "Vault $1 $2 returned $code: $(jq -r '.errors // [] | join("; ")' "$WORK/out" 2>/dev/null)" >&2; exit 1 ;; esac
}
header() { printf 'X-Vault-Token: %s\n' "$(jq -r "$1" "$WORK/out")" >"$WORK/$2"; }

must POST "auth/$AUTH/login" "$(jq -n --arg j "$(k -n "$NS" create token "$SA" --duration=10m)" --arg r "$ROLE" '{jwt: $j, role: $r}')"
header .auth.client_token operator
trap 'call POST auth/token/revoke-self "" "$WORK/operator" >/dev/null || true; rm -rf "$WORK"' EXIT

end=$((SECONDS + WAIT))
until [ "$(call GET "auth/$APPROLE/role/nico/role-id" "" "$WORK/operator")" = 200 ]; do
  [ $SECONDS -lt $end ] || { echo "the operator has not created the AppRole $APPROLE/role/nico" >&2; exit 1; }
  sleep 10
done
ROLE_ID=$(jq -r .data.role_id "$WORK/out")
must POST "auth/$APPROLE/role/nico/secret-id" "{}" "$WORK/operator"
SECRET_ID=$(jq -r .data.secret_id "$WORK/out")
must POST "auth/$APPROLE/login" "$(jq -n --arg r "$ROLE_ID" --arg s "$SECRET_ID" '{role_id: $r, secret_id: $s}')"
jq -e --arg p "$POLICY" '.auth.token_policies | index($p)' "$WORK/out" >/dev/null \
  || { echo "the minted token lacks $POLICY" >&2; exit 1; }
DAYS=$(jq -r '.auth.lease_duration / 86400 | floor' "$WORK/out")

if [ "$ROTATE" = true ] && k -n nico-system get secret nico-vault-token >/dev/null 2>&1; then
  printf 'X-Vault-Token: %s\n' "$(k -n nico-system get secret nico-vault-token -o jsonpath='{.data.token}' | base64 -d)" >"$WORK/old"
fi
k get namespace nico-system >/dev/null 2>&1 || k create namespace nico-system >/dev/null
jq -j .auth.client_token "$WORK/out" | k -n nico-system create secret generic nico-vault-token --from-file=token=/dev/stdin \
  --dry-run=client -o yaml | k apply -f - >/dev/null
echo "stored nico-system/nico-vault-token, valid for $DAYS days"

if [ -f "$WORK/old" ]; then
  if k -n nico-system get deploy/nico-api >/dev/null 2>&1; then
    k -n nico-system rollout restart deploy/nico-api >/dev/null
    k -n nico-system rollout status deploy/nico-api --timeout=10m >/dev/null
    echo "restarted nico-api on the new token"
  fi
  call POST auth/token/revoke-self "" "$WORK/old" >/dev/null || true
  echo "revoked the old token"
fi

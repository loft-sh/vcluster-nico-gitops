#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/platform-token.sh --context <global-context> --platform-host <host> [--org <provider-org>] [--ttl <seconds>]

Prints a short-lived PROVIDER_ADMIN token for NICo REST, signed with the vCluster
Platform's own OIDC key, the same way the Platform signs its NICo calls.
Needs read access to the Secret loft-cert in vcluster-platform.
EOF
  exit 2
}

CONTEXT=""; HOST=""; ORG="vcluster-autonodes"; TTL=600
AUDIENCE=http://nico-rest-api.nico-rest.svc.cluster.local:8388
while [ $# -gt 0 ]; do
  case "$1" in
    --context) CONTEXT=$2; shift 2 ;;
    --platform-host) HOST=$2; shift 2 ;;
    --org) ORG=$2; shift 2 ;;
    --ttl) TTL=$2; shift 2 ;;
    --audience) AUDIENCE=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$CONTEXT" ] && [ -n "$HOST" ] || usage

k() { kubectl --context "$CONTEXT" "$@"; }
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
k -n vcluster-platform get secret loft-cert -o jsonpath='{.data.tls\.key}' | base64 -d > "$WORK/key.pem"
KID=$(k get --raw /api/v1/namespaces/vcluster-platform/services/https:loft:443/proxy/oidc/keys | jq -r '.keys[0].kid')
[ -n "$KID" ] && [ "$KID" != null ] || { echo "could not read the Platform's signing key id" >&2; exit 1; }

NOW=$(date +%s)
HEADER=$(jq -cn --arg kid "$KID" '{alg: "RS256", typ: "JWT", kid: $kid}' | b64url)
PAYLOAD=$(jq -cn --arg iss "https://$HOST/oidc" --arg org "$ORG" --arg aud "$AUDIENCE" --argjson now "$NOW" --argjson ttl "$TTL" \
  '{iss: $iss, sub: ("platform:provider:" + $org), aud: [$aud], iat: $now, nbf: $now, exp: ($now + $ttl), organization: $org, roles: ["PROVIDER_ADMIN"]}' | b64url)
SIGNATURE=$(printf '%s.%s' "$HEADER" "$PAYLOAD" | openssl dgst -sha256 -sign "$WORK/key.pem" -binary | b64url)
printf '%s.%s.%s\n' "$HEADER" "$PAYLOAD" "$SIGNATURE"

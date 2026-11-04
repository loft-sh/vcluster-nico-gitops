#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: NICO_TOKEN=<jwt> scripts/register-site.sh \
         --global-context <ctx> --site-context <ctx> --name <site-name> \
         --rest-url <https://nico-rest-api...> --creds-url <https://site-manager.example.com:8100/v1/sitecreds> \
         [--org <provider-org>] [--description <text>]

Creates the site in NICo REST, waits for its one-time passcode on the global
cluster and writes the site-registration Secret the site agent bootstraps from.
Prints the site ID to put into the site's settings (siteId) and the NodeProvider.

  NICO_TOKEN   a JWT the REST API accepts with the PROVIDER_ADMIN role for --org
EOF
  exit 2
}

GLOBAL=""; SITE=""; NAME=""; REST=""; CREDS=""; ORG="vcluster-autonodes"; DESC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --global-context) GLOBAL=$2; shift 2 ;;
    --site-context) SITE=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --rest-url) REST=${2%/}; shift 2 ;;
    --creds-url) CREDS=$2; shift 2 ;;
    --org) ORG=$2; shift 2 ;;
    --description) DESC=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$GLOBAL" ] && [ -n "$SITE" ] && [ -n "$NAME" ] && [ -n "$REST" ] && [ -n "$CREDS" ] && [ -n "${NICO_TOKEN:-}" ] || usage

api() { curl -fsS -H "Authorization: Bearer $NICO_TOKEN" -H "Content-Type: application/json" "$@"; }

SITE_ID=$(api "$REST/v2/org/$ORG/nico/site" | jq -r --arg n "$NAME" '[.[] | select(.name == $n)][0].id // empty')
if [ -n "$SITE_ID" ]; then
  echo "site $NAME already exists: $SITE_ID"
else
  SITE_ID=$(api -X POST "$REST/v2/org/$ORG/nico/site" \
    -d "$(jq -n --arg n "$NAME" --arg d "${DESC:-NICo site $NAME}" '{name: $n, description: $d}')" | jq -r .id)
  echo "created site $NAME: $SITE_ID"
fi

OTP=""
for _ in $(seq 1 36); do
  OTP=$(kubectl --context "$GLOBAL" -n nico-rest get site "site-$SITE_ID" -o jsonpath='{.status.otp.passcode}' 2>/dev/null || true)
  [ -n "$OTP" ] && break
  sleep 5
done
[ -n "$OTP" ] || { echo "no one-time passcode on site-$SITE_ID after 3 minutes" >&2; exit 1; }

CACERT=$(kubectl --context "$GLOBAL" -n nico-rest get secret ca-signing-secret -o jsonpath='{.data.tls\.crt}' | base64 -d)

kubectl --context "$SITE" get namespace nico-rest >/dev/null 2>&1 || kubectl --context "$SITE" create namespace nico-rest >/dev/null
kubectl --context "$SITE" -n nico-rest create secret generic site-registration \
  --from-literal=site-uuid="$SITE_ID" --from-literal=otp="$OTP" \
  --from-literal=creds-url="$CREDS" --from-literal=cacert="$CACERT" \
  --dry-run=client -o yaml | kubectl --context "$SITE" apply -f - >/dev/null
echo "wrote nico-rest/site-registration on $SITE"

kubectl --context "$SITE" -n nico-rest delete pod -l app.kubernetes.io/name=nico-rest-site-agent --ignore-not-found >/dev/null
echo
echo "siteId: $SITE_ID"
echo "Set siteId in the site's settings and in the global nico-provider overrides, then commit."

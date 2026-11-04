#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
: "${SITE_ID:?}" "${PLATFORM_IP:?}" "${ORG:?}" "${GLOBAL:?}" "${SITE:?}" "${REST:?}"
fail=0
ok() { printf 'OK    %s\n' "$1"; }
bad() { printf 'FAIL  %s: %s\n' "$1" "$2"; fail=1; }
token() { "$ROOT/scripts/platform-token.sh" --context "$GLOBAL" --platform-host "$PLATFORM_IP" --org "$ORG"; }

for hr in cert-manager global-prereqs temporal temporal-namespaces nico-rest vcluster-platform nico-provider; do
  if kubectl --context "$GLOBAL" -n flux-system wait "helmrelease/$hr" --for=condition=Ready --timeout=60s >/dev/null 2>&1; then ok "global HelmRelease $hr Ready"; else bad "global HelmRelease $hr" "not Ready"; fi
done

if kubectl --context "$SITE" -n nico-rest wait pod/nico-rest-site-agent-0 --for=condition=Ready --timeout=15m >/dev/null 2>&1; then
  ok "site agent Ready after registration"
else
  bad "site agent" "$(kubectl --context "$SITE" -n nico-rest logs nico-rest-site-agent-0 --tail=5 2>&1 | tail -2)"
fi

status=""
for _ in $(seq 1 30); do
  status=$(curl -s -H "Authorization: Bearer $(token)" "$REST/v2/org/$ORG/nico/site/$SITE_ID" | jq -r '"\(.status) \(.isOnline)"')
  [ "$status" = "Registered true" ] && break
  sleep 20
done
if [ "$status" = "Registered true" ]; then ok "REST reports the site Registered and online"; else bad "REST site status" "$status"; fi

if [ -n "${LICENSE_TOKEN:-}" ]; then
  if kubectl --context "$GLOBAL" wait nodeproviders.management.loft.sh/nico-e2e --for=jsonpath='{.status.phase}'=Available --timeout=10m >/dev/null 2>&1; then
    ok "NodeProvider nico-e2e Available"
  else
    bad "NodeProvider nico-e2e" "$(kubectl --context "$GLOBAL" get nodeproviders.management.loft.sh nico-e2e -o jsonpath='{.status}' 2>&1 | tail -c 300)"
  fi
else
  echo "SKIP  NodeProvider check: no LICENSE_TOKEN"
fi
exit $fail

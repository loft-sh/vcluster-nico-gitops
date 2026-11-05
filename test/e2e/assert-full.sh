#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
: "${SITE_ID:?}" "${PLATFORM_IP:?}" "${ORG:?}" "${GLOBAL:?}" "${SITE:?}" "${REST:?}"
fail=0
ok() { printf 'OK    %s\n' "$1"; }
bad() { printf 'FAIL  %s: %s\n' "$1" "$2"; fail=1; }
token() { "$ROOT/scripts/platform-token.sh" --context "$GLOBAL" --platform-host "$PLATFORM_IP" --org "$ORG"; }

MODE=${MODE:-flux}
for c in cert-manager global-prereqs temporal temporal-namespaces nico-rest vcluster-platform nico-provider; do
  if [ "$MODE" = argocd ]; then
    s=$(kubectl --context "$GLOBAL" -n argocd get "application/$c" -o jsonpath='{.status.sync.status} {.status.health.status}' 2>&1)
    if [ "$s" = "Synced Healthy" ]; then ok "global Application $c Synced and Healthy"; else bad "global Application $c" "$s"; fi
  elif kubectl --context "$GLOBAL" -n flux-system wait "helmrelease/$c" --for=condition=Ready --timeout=60s >/dev/null 2>&1; then
    ok "global HelmRelease $c Ready"
  else
    bad "global HelmRelease $c" "not Ready"
  fi
done

if kubectl --context "$SITE" -n nico-rest wait pod/nico-rest-site-agent-0 --for=condition=Ready --timeout=15m >/dev/null 2>&1; then
  ok "site agent Ready after registration"
else
  bad "site agent" "$(kubectl --context "$SITE" -n nico-rest logs nico-rest-site-agent-0 --tail=5 2>&1 | tail -2)"
fi

if kubectl --context "$GLOBAL" wait clusters.management.loft.sh/e2e --for=jsonpath='{.status.phase}'=Initialized --timeout=10m >/dev/null 2>&1; then
  ok "Platform agent connected the site cluster to the Platform"
else
  bad "Platform cluster e2e" "$(kubectl --context "$GLOBAL" get clusters.management.loft.sh e2e -o jsonpath='{.status.phase} {.status.reason} {.status.message}' 2>&1 | tail -c 300)"
fi

status=""
for _ in $(seq 1 30); do
  status=$(curl -s -H "Authorization: Bearer $(token)" "$REST/v2/org/$ORG/nico/site/$SITE_ID" | jq -r '"\(.status) \(.isOnline)"')
  [ "$status" = "Registered true" ] && break
  sleep 20
done
if [ "$status" = "Registered true" ]; then ok "REST reports the site Registered and online"; else bad "REST site status" "$status"; fi

if [ "$MODE" = flux ] && [ -n "${LICENSE_TOKEN:-}" ]; then
  if kubectl --context "$GLOBAL" wait nodeproviders.management.loft.sh/nico-e2e --for=jsonpath='{.status.phase}'=Available --timeout=10m >/dev/null 2>&1; then
    ok "NodeProvider nico-e2e Available"
  else
    bad "NodeProvider nico-e2e" "$(kubectl --context "$GLOBAL" get nodeproviders.management.loft.sh nico-e2e -o jsonpath='{.status}' 2>&1 | tail -c 300)"
  fi
else
  echo "SKIP  NodeProvider check: no LICENSE_TOKEN"
fi
exit $fail

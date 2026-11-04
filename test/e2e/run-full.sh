#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
: "${BLUEPRINT_URL:?}" "${BLUEPRINT_BRANCH:?}" "${BLUEPRINT_COMMIT:?}" "${GIT_TOKEN:?}"
G=kind-nico-global
S=kind-nico-site
ORG=vcluster-autonodes

kind create cluster --name nico-global --config "$ROOT/test/e2e/kind.yaml"
kind create cluster --name nico-site --config "$ROOT/test/e2e/kind.yaml"

NET=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -1)
BASE=$(echo "$NET" | cut -d. -f1-2)
PLATFORM_IP=$BASE.255.200
TEMPORAL_IP=$BASE.255.202
SITE_MANAGER_IP=$BASE.255.203
SITE_MANAGER_HOST=$(echo "$SITE_MANAGER_IP" | tr . -).nip.io
echo "kind network $NET: platform $PLATFORM_IP, temporal $TEMPORAL_IP, site manager $SITE_MANAGER_HOST"

helm repo add metallb https://metallb.github.io/metallb >/dev/null
helm --kube-context "$G" install metallb metallb/metallb --version 0.15.3 -n metallb-system --create-namespace --wait >/dev/null
kubectl --context "$G" apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: e2e
  namespace: metallb-system
spec:
  addresses:
    - $BASE.255.200-$BASE.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: e2e
  namespace: metallb-system
EOF

render() {
  kubectl kustomize "$1" | sed -e "s|BLUEPRINT_URL|$BLUEPRINT_URL|g" -e "s|BLUEPRINT_BRANCH|$BLUEPRINT_BRANCH|g" \
    -e "s|BLUEPRINT_COMMIT|$BLUEPRINT_COMMIT|g" -e "s|PLATFORM_IP|$PLATFORM_IP|g" -e "s|TEMPORAL_IP|$TEMPORAL_IP|g" \
    -e "s|SITE_MANAGER_IP|$SITE_MANAGER_IP|g" -e "s|SITE_MANAGER_HOST|$SITE_MANAGER_HOST|g"
}

for c in "$G" "$S"; do
  flux install --context "$c" --components=source-controller,kustomize-controller,helm-controller
  flux create secret git blueprint-auth --context "$c" -n flux-system --url="$BLUEPRINT_URL" --username=x-access-token --password="$GIT_TOKEN"
done

"$ROOT/scripts/bootstrap-global-secrets.sh" --context "$G"
render "$ROOT/test/e2e/full/global/nico" | kubectl --context "$G" apply -f -

kubectl --context "$S" apply -f "$ROOT/test/e2e/vault-dev.yaml"
kubectl --context "$S" -n vault rollout status deploy/vault --timeout=300s
TOKEN=$(kubectl config use-context "$S" >/dev/null && "$ROOT/test/e2e/vault-setup.sh")
NICO_VAULT_TOKEN=$TOKEN "$ROOT/scripts/bootstrap-site-secrets.sh" --context "$S"
render "$ROOT/test/e2e/full/site/nico" | kubectl --context "$S" apply -f -

echo "waiting for the global control plane"
kubectl --context "$G" -n flux-system wait kustomization/nico-global --for=condition=Ready --timeout=45m
echo "waiting for the site"
kubectl --context "$S" -n flux-system wait kustomization/nico-site-base --for=condition=Ready --timeout=30m
kubectl --context "$S" -n flux-system wait helmrelease/nico --for=condition=Ready --timeout=30m

kubectl --context "$G" -n nico-rest port-forward svc/nico-rest-api 18388:8388 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
sleep 5
token() { "$ROOT/scripts/platform-token.sh" --context "$G" --platform-host "$PLATFORM_IP" --org "$ORG"; }

REG=$(NICO_TOKEN=$(token) "$ROOT/scripts/register-site.sh" --global-context "$G" --site-context "$S" --org "$ORG" \
  --name e2e --rest-url http://127.0.0.1:18388 --creds-url "https://$SITE_MANAGER_HOST:8100/v1/sitecreds")
echo "$REG"
SITE_ID=$(echo "$REG" | awk '/^siteId:/ {print $2}')
kubectl --context "$S" -n flux-system patch configmap blueprint-settings --type merge -p "{\"data\":{\"siteId\":\"$SITE_ID\"}}"

if [ -n "${LICENSE_TOKEN:-}" ]; then
  kubectl --context "$G" -n flux-system patch configmap blueprint-overrides-nico-provider --type merge \
    -p "{\"data\":{\"values.yaml\":\"sites:\\n  - name: nico-e2e\\n    siteId: $SITE_ID\\n\"}}"
fi

SITE_ID=$SITE_ID PLATFORM_IP=$PLATFORM_IP ORG=$ORG GLOBAL=$G SITE=$S REST=http://127.0.0.1:18388 \
  "$ROOT/test/e2e/assert-full.sh"

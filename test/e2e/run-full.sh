#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
: "${GITOPS_URL:?}" "${GITOPS_BRANCH:?}" "${GITOPS_COMMIT:?}" "${GIT_TOKEN:?}"
G=kind-nico-global
S=kind-nico-site
ORG=vcluster-autonodes
MODE=${MODE:-flux}
. "$ROOT/test/e2e/argocd-lib.sh"

docker network inspect kind >/dev/null 2>&1 || docker network create kind --subnet 172.18.0.0/16 \
  -o com.docker.network.bridge.enable_ip_masquerade=true -o com.docker.network.driver.mtu=1500 >/dev/null
kind create cluster --name nico-global --config "$ROOT/test/e2e/kind.yaml"
kind create cluster --name nico-site --config "$ROOT/test/e2e/kind.yaml"

NET=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -1)
BASE=$(echo "$NET" | cut -d. -f1-2)
[ "$BASE" = 172.18 ] || { echo "the test configs expect the kind network on 172.18.0.0/16, got $NET" >&2; exit 1; }
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
  kubectl kustomize "$1" | sed -e "s|GITOPS_URL|$GITOPS_URL|g" -e "s|GITOPS_BRANCH|$GITOPS_BRANCH|g" -e "s|GITOPS_COMMIT|$GITOPS_COMMIT|g"
}

for c in "$G" "$S"; do
  if [ "$MODE" = argocd ]; then
    argocd_install "$c"
  else
    flux install --context "$c" --components=source-controller,kustomize-controller,helm-controller
    flux create secret git gitops-auth --context "$c" -n flux-system --url="$GITOPS_URL" --username=x-access-token --password="$GIT_TOKEN"
  fi
done

"$ROOT/scripts/bootstrap-global-secrets.sh" --context "$G"
if [ "$MODE" = argocd ]; then
  argocd_root "$G" global test/e2e/full/global/nico
else
  render "$ROOT/test/e2e/full/global/nico" | kubectl --context "$G" apply -f -
fi

kubectl --context "$S" apply -f "$ROOT/test/e2e/vault-dev.yaml"
kubectl --context "$S" -n vault rollout status deploy/vault --timeout=300s
"$ROOT/scripts/bootstrap-site-secrets.sh" --context "$S"
GLOBAL_API=https://$(docker inspect -f '{{.NetworkSettings.Networks.kind.IPAddress}}' nico-global-control-plane):6443
if [ "$MODE" = argocd ]; then
  argocd_root "$S" vault-config test/e2e/full/site/nico
  argocd_root "$S" site-base test/e2e/full/site/nico
  argocd_root "$S" site test/e2e/full/site/nico
  "$ROOT/test/e2e/vault-config.sh" --context "$S"
  echo "waiting for the global control plane"
  for app in cert-manager global-prereqs temporal temporal-namespaces nico-rest vcluster-platform nico-provider; do
    argocd_synced "$G" "$app" 2700
  done
  echo "waiting for the site"
  for app in vault-config-operator vault-config cert-manager site-prereqs nico; do argocd_synced "$S" "$app" 2400; done
else
  render "$ROOT/test/e2e/full/site/nico" | kubectl --context "$S" apply -f -
  kubectl --context "$S" -n flux-system patch configmap gitops-settings --type merge \
    -p "{\"data\":{\"vaultGlobal\":\"true\",\"vaultGlobalKubernetesHost\":\"$GLOBAL_API\"}}"
  kubectl --context "$G" -n kube-system get configmap kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' \
    | jq -Rs '{global: {kubernetesCaCert: .}}' \
    | kubectl --context "$S" -n flux-system create configmap gitops-overrides-vault-config --from-file=values.yaml=/dev/stdin
  kubectl --context "$S" -n flux-system label configmap gitops-overrides-vault-config reconcile.fluxcd.io/watch=Enabled
  "$ROOT/test/e2e/vault-config.sh" --context "$S" --global-context "$G"
  echo "waiting for the global control plane"
  kubectl --context "$G" -n flux-system wait kustomization/nico-global --for=condition=Ready --timeout=45m
  echo "waiting for the site"
  kubectl --context "$S" -n flux-system wait kustomization/nico-vault-config --for=condition=Ready --timeout=30m
  kubectl --context "$S" -n flux-system wait kustomization/nico-site-base --for=condition=Ready --timeout=30m
  kubectl --context "$S" -n flux-system wait helmrelease/nico --for=create --timeout=15m
  kubectl --context "$S" -n flux-system wait helmrelease/nico --for=condition=Ready --timeout=30m
fi

kubectl --context "$G" -n nico-rest port-forward svc/nico-rest-api 18388:8388 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null || true' EXIT
sleep 5
token() { "$ROOT/scripts/platform-token.sh" --context "$G" --platform-host "$PLATFORM_IP" --org "$ORG"; }

REG=$(NICO_TOKEN=$(token) "$ROOT/scripts/register-site.sh" --global-context "$G" --site-context "$S" --org "$ORG" \
  --name e2e --rest-url http://127.0.0.1:18388 --creds-url "https://$SITE_MANAGER_HOST:8100/v1/sitecreds")
echo "$REG"
SITE_ID=$(echo "$REG" | awk '/^siteId:/ {print $2}')
"$ROOT/scripts/connect-site.sh" --global-context "$G" --site-context "$S" --name e2e
if [ "$MODE" = argocd ]; then
  argocd_root "$S" site test/e2e/full/site/nico "{siteId: \"$SITE_ID\"}"
else
  kubectl --context "$S" -n flux-system patch configmap gitops-settings --type merge -p "{\"data\":{\"siteId\":\"$SITE_ID\"}}"
fi

if [ "$MODE" = flux ] && [ -n "${LICENSE_TOKEN:-}" ]; then
  kubectl --context "$G" -n flux-system patch configmap gitops-overrides-nico-provider --type merge \
    -p "{\"data\":{\"values.yaml\":\"sites:\\n  - name: nico-e2e\\n    siteId: $SITE_ID\\n\"}}"
fi

MODE=$MODE SITE_ID=$SITE_ID PLATFORM_IP=$PLATFORM_IP ORG=$ORG GLOBAL=$G SITE=$S REST=http://127.0.0.1:18388 \
  "$ROOT/test/e2e/assert-full.sh"

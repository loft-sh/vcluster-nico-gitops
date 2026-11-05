#!/usr/bin/env bash
set -euo pipefail

ENV=${1:?usage: test/e2e/run-argocd.sh <site|site-dpu>}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
: "${GITOPS_URL:?}" "${GITOPS_COMMIT:?}" "${GIT_TOKEN:?}"
. "$ROOT/test/e2e/argocd-lib.sh"
CTX=$(kubectl config current-context)
ENV_PATH=test/e2e/$ENV/nico

argocd_install "$CTX"

kubectl apply -f "$ROOT/test/e2e/vault-dev.yaml"
kubectl -n vault rollout status deploy/vault --timeout=300s
FLAGS=()
[ "$ENV" = site-dpu ] && FLAGS=(--dpu)
"$ROOT/scripts/bootstrap-site-secrets.sh" --context "$CTX" "${FLAGS[@]}"

API_VIP=$(kubectl get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[0].ip}')
DATA="{dpfApiServerVip: \"$API_VIP\"}"

argocd_root "$CTX" site-base "$ENV_PATH" "$DATA"
argocd_root "$CTX" vault-config "$ENV_PATH" "$DATA"
"$ROOT/test/e2e/vault-config.sh" --context "$CTX"
echo "waiting for the vault-config and site-base layers"
argocd_synced "$CTX" vault-config-operator 1200
argocd_synced "$CTX" vault-config 1200
argocd_synced "$CTX" cert-manager 1200
argocd_synced "$CTX" site-prereqs 1200

if [ "$ENV" = site-dpu ]; then
  argocd_root "$CTX" site-dpu "$ENV_PATH" "$DATA"
  echo "waiting for the site-dpu layer"
  for app in argo-cd kamaji kamaji-datastore maintenance-operator node-feature-discovery dpf-operator dpf-config; do
    argocd_synced "$CTX" "$app" 2700
  done
fi

argocd_root "$CTX" site "$ENV_PATH" "$DATA"
echo "waiting for NICo Core"
argocd_synced "$CTX" nico 2400

MODE=argocd "$ROOT/test/e2e/assert.sh" "$ENV"

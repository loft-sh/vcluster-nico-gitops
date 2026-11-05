#!/usr/bin/env bash
set -euo pipefail

ENV=${1:?usage: test/e2e/run.sh <site|site-dpu>}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
: "${GITOPS_URL:?}" "${GITOPS_BRANCH:?}" "${GITOPS_COMMIT:?}" "${GIT_TOKEN:?}"
CTX=$(kubectl config current-context)

flux install --components=source-controller,kustomize-controller,helm-controller

kubectl apply -f "$ROOT/test/e2e/vault-dev.yaml"
kubectl -n vault rollout status deploy/vault --timeout=300s
TOKEN=$("$ROOT/test/e2e/vault-setup.sh")

FLAGS=()
[ "$ENV" = site-dpu ] && FLAGS=(--dpu)
NICO_VAULT_TOKEN=$TOKEN "$ROOT/scripts/bootstrap-site-secrets.sh" --context "$CTX" "${FLAGS[@]}"

flux create secret git gitops-auth -n flux-system --url="$GITOPS_URL" --username=x-access-token --password="$GIT_TOKEN"
API_VIP=$(kubectl get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[0].ip}')
kubectl kustomize "$ROOT/test/e2e/$ENV/nico" \
  | sed -e "s|GITOPS_URL|$GITOPS_URL|g" -e "s|GITOPS_BRANCH|$GITOPS_BRANCH|g" \
        -e "s|GITOPS_COMMIT|$GITOPS_COMMIT|g" -e "s|API_VIP|$API_VIP|g" \
  | kubectl apply -f -

layers=(nico-site-base)
[ "$ENV" = site-dpu ] && layers+=(nico-site-dpu)
for k in "${layers[@]}"; do
  echo "waiting for layer $k"
  kubectl -n flux-system wait "kustomization/$k" --for=condition=Ready --timeout=45m
done
kubectl -n flux-system wait kustomization/nico-site --for=condition=Ready --timeout=10m
echo "waiting for NICo Core"
kubectl -n flux-system wait helmrelease/nico --for=condition=Ready --timeout=30m

"$ROOT/test/e2e/assert.sh" "$ENV"

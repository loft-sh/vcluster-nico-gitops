#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
: "${BLUEPRINT_URL:?}" "${BLUEPRINT_COMMIT:?}" "${GIT_TOKEN:?}"
CTX=$(kubectl config current-context)
REPO=$BLUEPRINT_URL.git
ENV_PATH=test/e2e/argocd/site/nico
ARGO_VERSION=$(awk '/^dpf:/ {f = 1} f && $1 == "argo-cd:" {print $2; exit}' "$ROOT/versions.yaml")

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm install argocd argo/argo-cd --version "$ARGO_VERSION" -n argocd --create-namespace --wait \
  --set dex.enabled=false --set notifications.enabled=false --set applicationSet.replicas=0 >/dev/null

kubectl -n argocd apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vcluster-nico-blueprints
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: $REPO
  username: x-access-token
  password: $GIT_TOKEN
EOF

kubectl apply -f "$ROOT/test/e2e/vault-dev.yaml"
kubectl -n vault rollout status deploy/vault --timeout=300s
TOKEN=$("$ROOT/test/e2e/vault-setup.sh")
NICO_VAULT_TOKEN=$TOKEN "$ROOT/scripts/bootstrap-site-secrets.sh" --context "$CTX"

root() {
  cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nico-$1
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  sources:
    - repoURL: $REPO
      targetRevision: $BLUEPRINT_COMMIT
      path: patterns/argocd/$1
      helm:
        valueFiles:
          - \$env/$ENV_PATH/settings.yaml
        valuesObject:
          blueprint:
            repoURL: $REPO
            targetRevision: $BLUEPRINT_COMMIT
          environment:
            repoURL: $REPO
            targetRevision: $BLUEPRINT_COMMIT
            path: $ENV_PATH
    - repoURL: $REPO
      targetRevision: $BLUEPRINT_COMMIT
      ref: env
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
}

synced() {
  local end=$((SECONDS + $2)) s=
  until [ "$s" = "Synced Healthy Succeeded" ]; do
    [ $SECONDS -lt $end ] || { echo "application/$1 not synced: ${s:-missing}"; return 1; }
    sleep 10
    s=$(kubectl -n argocd get "application/$1" -o jsonpath='{.status.sync.status} {.status.health.status} {.status.operationState.phase}' 2>/dev/null)
  done
}

root site-base | kubectl apply -f -
echo "waiting for the site-base layer"
synced cert-manager 1200
synced site-prereqs 1200

root site | kubectl apply -f -
echo "waiting for NICo Core"
synced nico 2400

MODE=argocd "$ROOT/test/e2e/assert.sh" site

ARGO_VERSION=$(awk '/^dpf:/ {f = 1} f && $1 == "argo-cd:" {print $2; exit}' "$ROOT/versions.yaml")
REPO=$GITOPS_URL.git

argocd_install() {
  local ctx=$1
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
  helm --kube-context "$ctx" install argocd argo/argo-cd --version "$ARGO_VERSION" -n argocd --create-namespace --wait \
    --set dex.enabled=false --set notifications.enabled=false --set applicationSet.replicas=0 >/dev/null
  kubectl --context "$ctx" -n argocd apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: vcluster-nico-gitops
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: $REPO
  username: x-access-token
  password: $GIT_TOKEN
YAML
}

argocd_root() {
  local ctx=$1 layer=$2 env=$3 data=${4:-"{}"}
  kubectl --context "$ctx" apply -f - <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nico-$layer
  namespace: argocd
spec:
  project: default
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  sources:
    - repoURL: $REPO
      targetRevision: $GITOPS_COMMIT
      path: patterns/argocd/$layer
      helm:
        valueFiles:
          - \$env/$env/settings.yaml
        valuesObject:
          data: $data
          gitops:
            repoURL: $REPO
            targetRevision: $GITOPS_COMMIT
          environment:
            repoURL: $REPO
            targetRevision: $GITOPS_COMMIT
            path: $env
    - repoURL: $REPO
      targetRevision: $GITOPS_COMMIT
      ref: env
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
YAML
}

argocd_synced() {
  local ctx=$1 app=$2 end=$((SECONDS + $3)) s=
  until [ "$s" = "Synced Healthy Succeeded" ] || [ "$s" = "Synced Healthy " ]; do
    [ $SECONDS -lt $end ] || { echo "application/$app not synced: ${s:-missing}"; return 1; }
    sleep 10
    s=$(kubectl --context "$ctx" -n argocd get "application/$app" \
      -o jsonpath='{.status.sync.status} {.status.health.status} {.status.operationState.phase}' 2>/dev/null)
  done
}

#!/usr/bin/env bash
set -uo pipefail

ENV=${1:?usage: test/e2e/assert.sh <site|site-dpu|site-vault>}
fail=0
ok() { printf 'OK    %s\n' "$1"; }
bad() { printf 'FAIL  %s: %s\n' "$1" "$2"; fail=1; }
check() { local name=$1; shift; if out=$("$@" 2>&1); then ok "$name"; else bad "$name" "$(echo "$out" | tail -2)"; fi; }
has() { local name=$1 want=$2; shift 2; out=$("$@" 2>&1); if grep -q -- "$want" <<<"$out"; then ok "$name"; else bad "$name" "$(echo "$out" | tail -2)"; fi; }

MODE=${MODE:-flux}
released() {
  if [ "$MODE" = argocd ]; then
    has "Application $1 Synced and Healthy" "^Synced Healthy$" kubectl -n argocd get "application/$1" -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
  else
    check "HelmRelease $1 Ready" kubectl -n flux-system wait "helmrelease/$1" --for=condition=Ready --timeout=60s
  fi
}
for app in cert-manager site-prereqs nico; do released "$app"; done
check "ClusterIssuer vault-nico-issuer Ready (cert-manager logs in to Vault)" \
  kubectl wait clusterissuer/vault-nico-issuer --for=condition=Ready --timeout=120s
check "every Certificate in nico-system Ready" kubectl -n nico-system wait certificate --all --for=condition=Ready --timeout=300s
check "nico-api available" kubectl -n nico-system wait deploy/nico-api --for=condition=Available --timeout=300s
has "nico-api logged in to Vault with the static token" "successfully refreshed vault token" \
  kubectl -n nico-system logs deploy/nico-api --tail=-1
has "NICo migrations applied" "^[1-9]" \
  kubectl -n nico-system exec nico-postgres-0 -- psql -U postgres -d nico -At -c "select count(*) from _sqlx_migrations"
has "site agent installed, waiting for registration" "nico-rest-site-agent" \
  kubectl -n nico-rest get statefulset nico-rest-site-agent -o name

if [ "$ENV" = site-vault ]; then
  for i in 0 1 2; do
    has "vault-$i unsealed" '"sealed": false' kubectl -n vault exec "vault-$i" -- vault status -format=json
  done
  check "vault-unseal configured Vault" kubectl -n vault wait deploy/vault-unseal --for=condition=Available --timeout=60s
  kubectl -n vault delete pod -l app.kubernetes.io/name=vault,component=server --wait=false >/dev/null
  sleep 20
  check "every Vault pod unsealed again after all restart at once" \
    kubectl -n vault wait pod -l app.kubernetes.io/name=vault,component=server --for=condition=Ready --timeout=300s
  check "nico-api still available after the Vault restart" kubectl -n nico-system wait deploy/nico-api --for=condition=Available --timeout=300s
fi

if [ "$ENV" = site-dpu ]; then
  for app in argo-cd kamaji kamaji-datastore maintenance-operator node-feature-discovery dpf-operator dpf-config; do released "$app"; done
  check "Kamaji controller available" kubectl -n dpf-operator-system wait deploy/kamaji --for=condition=Available --timeout=300s
  has "Kamaji DataStore webhook back to Fail" "Fail" kubectl get validatingwebhookconfiguration kamaji-validating-webhook-configuration \
    -o jsonpath='{.webhooks[?(@.name=="vdatastore.kb.io")].failurePolicy}'
  check "DPF operator available" kubectl -n dpf-operator-system wait deploy/dpf-operator-controller-manager --for=condition=Available --timeout=300s
  check "DPUCluster Ready" kubectl -n dpf-operator-system wait dpucluster/carbide-dpf-cluster --for=condition=Ready --timeout=900s
  has "NICo created its DPUDeployment" "nico-deployment-v2" kubectl -n dpf-operator-system get dpudeployments.svc.dpu.nvidia.com -o name
  has "NICo created a DPUFlavor" "dpuflavor" kubectl -n dpf-operator-system get dpuflavors.provisioning.dpu.nvidia.com -o name
  has "NICo created a BFB" "bfb" kubectl -n dpf-operator-system get bfbs.provisioning.dpu.nvidia.com -o name
  has "NICo DPU services point at the public images" "ghcr.io/loft-sh/vcluster-platform-nico" \
    kubectl -n dpf-operator-system get dpuservicetemplates -o yaml
fi
exit $fail

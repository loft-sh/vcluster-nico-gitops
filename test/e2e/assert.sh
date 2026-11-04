#!/usr/bin/env bash
set -uo pipefail

ENV=${1:?usage: test/e2e/assert.sh <site|site-dpu>}
fail=0
ok() { printf 'OK    %s\n' "$1"; }
bad() { printf 'FAIL  %s: %s\n' "$1" "$2"; fail=1; }
check() { local name=$1; shift; if out=$("$@" 2>&1); then ok "$name"; else bad "$name" "$(echo "$out" | tail -2)"; fi; }
has() { local name=$1 want=$2; shift 2; out=$("$@" 2>&1); if echo "$out" | grep -q -- "$want"; then ok "$name"; else bad "$name" "$(echo "$out" | tail -2)"; fi; }

for hr in cert-manager site-prereqs nico; do
  check "HelmRelease $hr Ready" kubectl -n flux-system wait "helmrelease/$hr" --for=condition=Ready --timeout=60s
done
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

if [ "$ENV" = site-dpu ]; then
  for hr in argo-cd kamaji kamaji-datastore maintenance-operator node-feature-discovery dpf-operator dpf-config; do
    check "HelmRelease $hr Ready" kubectl -n flux-system wait "helmrelease/$hr" --for=condition=Ready --timeout=60s
  done
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

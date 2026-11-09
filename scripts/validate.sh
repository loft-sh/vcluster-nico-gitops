#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
EXAMPLE=$ROOT/examples/customer-repo/clusters
ver() { python3 -c 'import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for k in sys.argv[2:]: d = d[k]
print(d)' "$ROOT/versions.yaml" "$@"; }
NICO_VERSION=$(ver nico version)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export HELM_CACHE_HOME=$WORK/helm-cache HELM_CONFIG_HOME=$WORK/helm-config HELM_REPOSITORY_CONFIG=$WORK/helm-repos.yaml
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo add loft https://charts.loft.sh >/dev/null
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo add nfd https://kubernetes-sigs.github.io/node-feature-discovery/charts >/dev/null
helm repo add doca https://helm.ngc.nvidia.com/nvidia/doca >/dev/null
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null
helm repo update >/dev/null

if [ -z "${NICO_CHARTS:-}" ]; then
  NICO_CHARTS=$WORK/nico-charts
  for c in nico nico-rest nico-rest-site-agent temporal; do
    helm pull "oci://ghcr.io/loft-sh/vcluster-platform-nico/charts/$c" --version "${NICO_VERSION#v}" --untar -d "$NICO_CHARTS" >/dev/null
  done
fi

fail=0
check() {
  local name=$1; shift
  if "$@" >"$WORK/out" 2>"$WORK/err"; then
    printf 'ok    %-28s %s objects\n' "$name" "$(grep -c '^kind:' "$WORK/out" || true)"
  else
    printf 'FAIL  %s\n' "$name"; sed 's/^/      /' "$WORK/err" | tail -5; fail=1
  fi
}
settings() { awk -v k="$2:" '$1 == k { $1 = ""; sub(/^ /, ""); gsub(/"/, ""); print }' "$EXAMPLE/$1/nico/settings.yaml"; }

for scope in global site-vault site-base site-dpu site site-telemetry; do
  check "flux pattern $scope" kubectl kustomize "$ROOT/patterns/flux/$scope"
done
for cluster in global site-1 site-dpu-1; do
  check "flux example $cluster" kubectl kustomize "$EXAMPLE/$cluster/nico"
done
check "argocd pattern global" helm template root "$ROOT/patterns/argocd/global" -f "$EXAMPLE/global/nico/settings.yaml"
for scope in site-vault site-base site-dpu site site-telemetry; do
  check "argocd pattern $scope" helm template root "$ROOT/patterns/argocd/$scope" -f "$EXAMPLE/site-dpu-1/nico/settings.yaml"
done

G=$EXAMPLE/global/nico/overrides
S=$EXAMPLE/site-1/nico/overrides
SITE_ID=11111111-2222-3333-4444-555555555555
check "vault" helm template vault hashicorp/vault --version "$(ver vault chart)" -n vault -f "$ROOT/values/site-vault/vault.yaml"
check "vault-unseal" helm template vault-unseal "$ROOT/charts/vault-unseal" -n vault
check "cert-manager" helm template cert-manager jetstack/cert-manager --version "$(ver cert-manager)" -n cert-manager --set crds.enabled=true
check "global-prereqs" helm template global-prereqs "$ROOT/charts/global-prereqs" -n nico-rest -f "$G/global-prereqs.yaml"
check "temporal" helm template temporal "$NICO_CHARTS/temporal" -n temporal \
  -f "$NICO_CHARTS/temporal/values.yaml" -f "$NICO_CHARTS/temporal/values-kind.yaml" \
  -f "$ROOT/values/global/temporal.yaml" -f "$G/temporal.yaml"
check "temporal-namespaces" helm template temporal-namespaces "$ROOT/charts/temporal-namespaces" -n temporal
check "nico-rest" helm template nico-rest "$NICO_CHARTS/nico-rest" -n nico-rest -f "$ROOT/values/global/nico-rest.yaml" \
  --set "nico-rest-api.config.issuers[0].issuer=$(settings global platformOidcIssuer)" \
  --set "nico-rest-site-manager.certificate.dnsNames[5]=$(settings global siteManagerHost)"
check "vcluster-platform" helm template vcluster-platform loft/vcluster-platform --version "$(ver vcluster-platform)" -n vcluster-platform \
  -f "$ROOT/values/global/vcluster-platform.yaml" --set "config.loftHost=$(settings global platformHost)"
check "nico-provider" helm template nico-provider "$ROOT/charts/nico-provider" -f "$G/nico-provider.yaml" --set "sites[0].siteId=$SITE_ID"
check "site-prereqs" helm template site-prereqs "$ROOT/charts/site-prereqs" -n nico-system --set "vault.address=$(settings site-1 vaultAddr)"
check "nico" helm template nico "$NICO_CHARTS/nico" -n nico-system -f "$ROOT/values/site/nico.yaml" -f "$S/nico.yaml"
check "nico-site-agent" helm template nico-rest-site-agent "$NICO_CHARTS/nico-rest-site-agent" -n nico-rest \
  -f "$ROOT/values/site/nico-site-agent.yaml" --set "envConfig.CLUSTER_ID=$SITE_ID" --set "envConfig.TEMPORAL_SUBSCRIBE_NAMESPACE=$SITE_ID"
check "site-relay" helm template site-relay oci://ghcr.io/open-telemetry/opentelemetry-helm-charts/opentelemetry-collector --version "$(ver opentelemetry-collector chart)" -n observability \
  -f "$ROOT/values/site-telemetry/site-relay.yaml" \
  --set-string "config.exporters.otlp_http/gateway.endpoint=$(settings site-1 telemetryEndpoint)" \
  --set-string "config.exporters.otlp_http/gateway.headers.X-Vcluster-Platform-Site=$(settings site-1 telemetrySite)" \
  --set-string "config.processors.resource/site.attributes[0].value=$(settings site-1 telemetrySite)" \
  --set-string "extraVolumes[0].secret.secretName=$(settings site-1 telemetrySecret)"

D=$EXAMPLE/site-dpu-1/nico/overrides
check "argo-cd" helm template argo-cd argo/argo-cd --version "$(ver dpf argo-cd)" -n dpf-operator-system -f "$ROOT/values/site-dpu/argo-cd.yaml"
check "kamaji" helm template kamaji oci://ghcr.io/nvidia/charts/kamaji --version "$(ver dpf kamaji)" -n dpf-operator-system \
  -f "$ROOT/values/site-dpu/kamaji.yaml" -f "$D/kamaji.yaml"
check "kamaji-datastore" helm template kamaji-datastore "$ROOT/charts/kamaji-datastore" -n dpf-operator-system
check "maintenance-operator" helm template maintenance-operator oci://ghcr.io/mellanox/maintenance-operator-chart --version "$(ver dpf maintenance-operator)" \
  -n dpf-operator-system -f "$ROOT/values/site-dpu/maintenance-operator.yaml"
check "node-feature-discovery" helm template node-feature-discovery nfd/node-feature-discovery --version "$(ver dpf node-feature-discovery)" \
  -n dpf-operator-system -f "$ROOT/values/site-dpu/node-feature-discovery.yaml"
check "dpf-operator" helm template dpf-operator doca/dpf-operator --version "$(ver dpf operator)" -n dpf-operator-system \
  -f "$ROOT/values/site-dpu/dpf-operator.yaml"
check "dpf-config" helm template dpf-config "$ROOT/charts/dpf-config" -n dpf-operator-system \
  --set "apiServer.vip=$(settings site-dpu-1 dpfApiServerVip)" --set "dpuCluster.keepalived.interface=$(settings site-dpu-1 dpuClusterInterface)" \
  --set "dpuCluster.keepalived.vip=$(settings site-dpu-1 dpuClusterVip)"
check "nico with dpf" helm template nico "$NICO_CHARTS/nico" -n nico-system -f "$ROOT/values/site/nico.yaml" -f "$D/nico.yaml"

for f in "$ROOT"/scripts/*.sh "$ROOT"/test/e2e/*.sh; do bash -n "$f" || { echo "FAIL  syntax $f"; fail=1; }; done
python3 "$ROOT/scripts/check-firmware.py" >"$WORK/fw" || { echo "FAIL  firmware"; sed 's/^/      /' "$WORK/fw"; fail=1; }
exit $fail

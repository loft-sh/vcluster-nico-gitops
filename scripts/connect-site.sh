#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF2'
usage: scripts/connect-site.sh --global-context <ctx> --site-context <ctx> --name <cluster-name> [--display-name <text>]

Adds the site cluster to the vCluster Platform and writes the agent's access key
to vcluster-platform/vcluster-platform-agent on the site. The site layer's Platform
agent connects with it.
EOF2
  exit 2
}

GLOBAL=""; SITE=""; NAME=""; DISPLAY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --global-context) GLOBAL=$2; shift 2 ;;
    --site-context) SITE=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --display-name) DISPLAY=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$GLOBAL" ] && [ -n "$SITE" ] && [ -n "$NAME" ] || usage

kubectl --context "$GLOBAL" apply -f - >/dev/null <<YAML
apiVersion: management.loft.sh/v1
kind: Cluster
metadata:
  name: $NAME
  annotations:
    loft.sh/cluster-ignore-agent: "true"
spec:
  displayName: ${DISPLAY:-$NAME}
  managementNamespace: vcluster-platform
  networkPeer: true
YAML
echo "cluster $NAME is on the Platform"

KEY=$(kubectl --context "$GLOBAL" get --raw "/apis/management.loft.sh/v1/clusters/$NAME/accesskey")
kubectl --context "$SITE" get namespace vcluster-platform >/dev/null 2>&1 || kubectl --context "$SITE" create namespace vcluster-platform >/dev/null
jq -n --argjson k "$KEY" '{apiVersion: "v1", kind: "Secret", metadata: {name: "vcluster-platform-agent", namespace: "vcluster-platform"},
  stringData: {token: $k.accessKey, url: $k.loftHost}}' | kubectl --context "$SITE" apply -f - >/dev/null
echo "stored vcluster-platform/vcluster-platform-agent on the site"
if [ "$(jq -r .insecure <<<"$KEY")" = true ]; then
  echo "the Platform reports an untrusted certificate: set insecureSkipVerify: true in overrides/vcluster-platform-agent.yaml, or give the Platform a trusted one"
fi

#!/usr/bin/env bash
set -euo pipefail

CTX=${1:?usage: test/e2e/dpu-cluster-standin.sh <context>}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)

helm repo add external-secrets https://charts.external-secrets.io >/dev/null
helm --kube-context "$CTX" install external-secrets external-secrets/external-secrets --version 2.10.0 \
  -n external-secrets --create-namespace --wait >/dev/null

kubectl --context "$CTX" create namespace dpu-cluster
kubectl --context "$CTX" -n dpu-cluster apply -f "$ROOT/charts/dpu-cluster/files/kubeconfig-reader.yaml"
kubectl --context "$CTX" -n dpu-cluster create secret generic dpu-cluster-admin --from-literal=config="apiVersion: v1
kind: Config
clusters:
  - name: dpu-cluster
    cluster:
      server: https://dpu-cluster.invalid:443
users:
  - name: dpu-cluster
    user:
      token: stand-in
contexts:
  - name: dpu-cluster
    context:
      cluster: dpu-cluster
      user: dpu-cluster
current-context: dpu-cluster
"

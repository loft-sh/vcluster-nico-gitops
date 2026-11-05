#!/usr/bin/env bash
set +e
flux get all -A
kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}: {.status.sync.status} {.status.health.status} {.status.operationState.phase} {.status.operationState.message} {.status.conditions}{"\n"}{end}' 2>/dev/null
kubectl get pods -A -o wide
kubectl get events -A --sort-by=.lastTimestamp | tail -60
for ns in nico-system nico-rest cert-manager vault dpf-operator-system; do
  for p in $(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '$3 != "Completed" {split($2, r, "/"); if ($3 != "Running" || r[1] != r[2]) print $1}'); do
    echo "=== $ns/$p"; kubectl -n "$ns" describe pod "$p" | tail -30; kubectl -n "$ns" logs "$p" --all-containers --tail=50
  done
done
kubectl -n nico-system logs deploy/nico-api --tail=200
kubectl get dpfoperatorconfig,dpucluster -A -o yaml 2>/dev/null | tail -80

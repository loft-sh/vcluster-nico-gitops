# Site telemetry

The `site-telemetry` layer runs a relay on each node of the site. It sends the site's NICo and cert-manager metrics, node metrics and pod logs to the Platform's observability gateway.

The gateway labels the data with the site only, never with a tenant, so only Platform admins can read it.

## Use it

1. In the Platform, create an access key that may write metrics for the site's cluster.
2. Create the Secret in the site cluster:
   ```bash
   kubectl create namespace observability
   kubectl -n observability create secret generic site-relay-gateway --from-literal=token=<access key> --from-file=ca.crt=<gateway CA>
   ```
3. Set `telemetryEndpoint`, `telemetrySite` and `telemetrySecret` in `settings.yaml`.
4. Add the layer after `site`. With Flux:
   ```yaml
   apiVersion: kustomize.toolkit.fluxcd.io/v1
   kind: Kustomization
   metadata:
     name: nico-site-telemetry
     namespace: flux-system
   spec:
     interval: 10m
     path: ./patterns/flux/site-telemetry
     prune: true
     wait: false
     timeout: 30m
     sourceRef:
       kind: GitRepository
       name: vcluster-nico-gitops
   ```
   With Argo CD, add a root Application for `patterns/argocd/site-telemetry`.

To rotate the key, update the Secret, then restart the relay with `kubectl -n observability rollout restart daemonset site-relay`.

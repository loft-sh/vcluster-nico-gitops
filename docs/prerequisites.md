# Prerequisites

## Clusters

- Global: Kubernetes 1.30+, 8 CPU, 32 GB.
- Each site: Kubernetes 1.30+ on the network the machines boot from.
- Flux or Argo CD on each.

## DNS

| Name | Points at |
|---|---|
| `platform.example.com` | vCluster Platform |
| `site-manager.example.com` | site manager, port 8100 |
| `temporal.example.com` | Temporal, port 7233 |

Sites need outbound 443, 8100 and 7233 to these.

## Vault, per site

1. A KV v2 mount, e.g. `nico-kv`.
2. A PKI mount, e.g. `nico-pki`, with a role, e.g. `nico-cluster`.
3. Kubernetes auth, with a role for the service account `cert-manager-vault` in `cert-manager` that can sign on that role.
4. A token for NICo with this policy:

   ```hcl
   path "nico-kv/data/machines/*"     { capabilities = ["create", "read", "update", "patch", "delete", "list"] }
   path "nico-kv/metadata/machines/*" { capabilities = ["read", "list", "delete"] }
   path "nico-kv/data/nico/*"         { capabilities = ["read", "list"] }
   path "nico-pki/sign/nico-cluster"  { capabilities = ["create", "update"] }
   path "nico-pki/issue/nico-cluster" { capabilities = ["create", "update"] }
   path "nico-pki/cert/ca"            { capabilities = ["read"] }
   ```

   Give it a long lifetime. Vault's default is 32 days.

## Argo CD

The layers order their Applications with sync waves. Argo CD only waits for an Application to be healthy if it checks Application health, so add this to `argocd-cm`. Without it, a layer can sync before cert-manager is ready and stall.

```yaml
resource.customizations.health.argoproj.io_Application: |
  hs = {}
  hs.status = "Progressing"
  hs.message = ""
  if obj.status ~= nil then
    if obj.status.health ~= nil then
      hs.status = obj.status.health.status
      if obj.status.health.message ~= nil then
        hs.message = obj.status.health.message
      end
    end
  end
  return hs
```

## Licence

The vCluster Platform licence must include NICo nodes. Pass it as `LICENSE_TOKEN` to `scripts/bootstrap-global-secrets.sh`.

# Settings

Each cluster has a `nico/settings.yaml`. Anything else goes in `nico/overrides/<component>.yaml` as Helm values.

## Global

| Key | Example |
|---|---|
| `platformHost` | `platform.example.com` |
| `platformOidcIssuer` | `https://platform.example.com/oidc` |
| `siteManagerHost` | `site-manager.example.com` |
| `nicoOrg` | `vcluster-autonodes` |
| `storageClass` | empty for the default |

## Site

| Key | Example |
|---|---|
| `siteId` | empty until the site is registered |
| `temporalHost` | `temporal.example.com` |
| `vaultAddr` | `https://vault.example.com` |
| `vaultKvMount` | `nico-kv` |
| `vaultPkiMount` | `nico-pki` |
| `vaultPkiRole` | `nico-cluster` |
| `vaultCertManagerAuthMount` | `kubernetes` |
| `vaultCertManagerRole` | `cert-manager` |
| `storageClass` | empty for the default |

## DPU sites

| Key | Example |
|---|---|
| `dpfApiServerVip` | site API address the DPUs can reach |
| `dpfApiServerPort` | `"6443"` |
| `dpuClusterMaxNodes` | `"1000"`, the most DPUs the DPU cluster takes |

## Site telemetry

| Key | Example |
|---|---|
| `telemetryEndpoint` | `https://gateway.example.com:4318` |
| `telemetrySite` | the site's cluster name in the Platform |
| `telemetrySecret` | `site-relay-gateway` |

## Overrides you'll need

- `nico.yaml` (site): the NICo site config. Start from the example. `dhcp_servers` takes IP addresses, not names.
- `nico-provider.yaml` (global): one entry per site.
- `dpu-cluster.yaml` (global): one entry per DPU site. See [dpu-management.md](dpu-management.md).

Helm replaces lists. If you add an issuer in `nico-rest.yaml`, keep the Platform issuer first.

# vCluster NICo GitOps

GitOps setup for NICo sites and the global control plane. Reference it from your own repo with Flux or Argo CD.

## Layers

| Layer | Installs | Needed by |
|---|---|---|
| `global` | vCluster Platform, NICo REST, Temporal | the global cluster |
| `site-vault` | Vault, unsealed automatically. A stop-gap, see [docs/vault.md](docs/vault.md) | sites without their own Vault |
| `site-base` | cert-manager, Vault issuer, Postgres | every site |
| `site-dpu` | DPF, for BlueField DPUs | DPU sites only |
| `site` | NICo Core, site agent | every site |
| `site-telemetry` | a relay that sends site telemetry to the Platform, see [docs/telemetry.md](docs/telemetry.md) | sites that send telemetry |

## Patterns

Each layer comes in two versions. Use the one that matches your GitOps tool. They install the same thing.

| Tool | Where | How |
|---|---|---|
| Flux | `patterns/flux/<layer>` | HelmReleases, ordered with `dependsOn` |
| Argo CD | `patterns/argocd/<layer>` | an Application per component, ordered with sync waves |

You don't copy the patterns. Your repo points Flux or Argo CD at them, pinned to a release tag:

- **Reference** this repo directly. Upgrade by changing the tag.
- **Mirror** it into your own Git and point at the mirror. Same upgrades, nothing reaches outside your network.

Either way, only the URL in `gitops.yaml` or `argocd-root.yaml` changes.

NICo's charts and images come from `ghcr.io/loft-sh/vcluster-platform-nico`. To stay offline, mirror those too.

## Use it

1. Pick the layers for each cluster from the table above.
2. Copy the matching example into your repo: `global`, `site-1` (no DPUs) or `site-dpu-1`, from `examples/customer-repo/clusters/`.
3. Fill in `settings.yaml` and `overrides/`. See [docs/settings.md](docs/settings.md).
4. Create the secrets:
   ```bash
   scripts/bootstrap-global-secrets.sh --context <global>
   ```
   ```bash
   NICO_VAULT_TOKEN=<token> scripts/bootstrap-site-secrets.sh --context <site> [--dpu]
   ```
5. Point your tool at the patterns:
   - Flux: add the `nico` folder to the cluster. Its `gitops.yaml` references `patterns/flux/<layer>`.
   - Argo CD: apply `nico/argocd-root.yaml`. It references `patterns/argocd/<layer>`.
6. Register each site: [docs/site-onboarding.md](docs/site-onboarding.md).

All versions are in [versions.yaml](versions.yaml). Before you start: [docs/prerequisites.md](docs/prerequisites.md).

## Changing this repo

Change a version in `versions.yaml`, or a component in `scripts/generate-patterns.py`, then run the generator and `scripts/validate.sh`. CI runs the same check plus a kind deploy of a site and a DPU site.

# Your repo

Copy `clusters/` into your repo.

| Example | Layers |
|---|---|
| `global` | global |
| `site-1` | vault-config, site-base, site |
| `site-dpu-1` | vault-config, site-base, site-dpu, site |

Each `nico/` folder has:
- `settings.yaml` and `overrides/`: your values.
- `kustomization.yaml` and `gitops.yaml`: for Flux.
- `argocd-root.yaml`: for Argo CD.

Change the repo URLs, then the settings. When you add an override file, add it to `kustomization.yaml` too.

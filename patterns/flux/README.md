# Flux

One folder per layer. Each has the sources, the HelmReleases and this repo's defaults.

Values are applied in this order: this repo's defaults, your `gitops-settings`, your `gitops-overrides-<component>`.

Your repo must define a GitRepository named `vcluster-nico-gitops`. See the examples.

These files are generated. Edit `scripts/generate-patterns.py` instead.

# Flux

One folder per layer. Each has the sources, the HelmReleases and the blueprint defaults.

Values are applied in this order: blueprint defaults, your `blueprint-settings`, your `blueprint-overrides-<component>`.

Your repo must define a GitRepository named `vcluster-nico-blueprints`. See the examples.

These files are generated. Edit `scripts/generate-patterns.py` instead.

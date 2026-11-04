# Argo CD

One chart per layer. Each renders an Argo CD Application per component. Your root Application passes in your `settings.yaml`.

Components are ordered with sync waves and retry until their dependencies exist.

These files are generated. Edit `scripts/generate-patterns.py` instead.

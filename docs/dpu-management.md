# DPU management

The `site-dpu` layer installs DPF, which NICo uses to manage BlueField DPUs. All of it is public.

## Turn it on

1. Run `scripts/bootstrap-site-secrets.sh` with `--dpu`.
2. Set the DPU keys in `settings.yaml`.
3. In `overrides/nico.yaml`, set `nico-api.dpf.rbacCreate: true` and `[dpf] enabled = true`. Copy the rest from the `site-dpu-1` example.
4. Install `site-dpu` before NICo first starts. The Flux example does this for you. With Argo CD, let `nico-site-dpu` go healthy first.

Choose `num_of_vfs` before onboarding DPUs. Changing it later reprovisions every DPU.

DPF uses the site BMC root credential from Vault at `<kv>/machines/bmc/site/root`.

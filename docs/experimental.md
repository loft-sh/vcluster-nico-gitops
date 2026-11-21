# Experimental

The NICo build in `versions.yaml`, `v2.4.0-rc.11.vcluster.5`, is NICo `v2.4.0-rc.11` plus the upstream PRs below, before NVIDIA merges them.

| PR | Adds | Database change | Turn it on |
|---|---|---|---|
| [#7777](https://github.com/dsx-ai-factory/infra-controller/pull/7777) | `retainBmcCredentials` on REST expected machines: NICo keeps the BMC password instead of rotating it | Yes. NICo REST adds `expected_machine.retain_bmc_credentials` | `retainBmcCredentials: true` on the expected machine |
| [#8327](https://github.com/dsx-ai-factory/infra-controller/pull/8327) | Named BIOS profiles, picked per machine | No | `named_bios_profiles` in `nico.yaml`, and a `bios-profile=<name>` machine label |
| [#8961](https://github.com/dsx-ai-factory/infra-controller/pull/8961) | Writes a host's named BIOS profile again when its BIOS drifted, and restarts the host. If the BIOS still differs after the restart, NICo raises the `BiosProfileDriftPersistent` alert and stops there | No | Always on, for hosts with a `bios-profile` label |
| [#8244](https://github.com/dsx-ai-factory/infra-controller/pull/8244) | The BIOS step waits until the host boots again | No | Always on. The first DPU restart delay is off unless you set `dpu_first_restart_delay` under `[machine_state_controller]` |
| [#8953](https://github.com/dsx-ai-factory/infra-controller/pull/8953) | Waits instead of restarting the host when the BMC is busy during BIOS setup | No | Always on |
| [#8955](https://github.com/dsx-ai-factory/infra-controller/pull/8955) | Restarts the host for a BIOS change in its own step, so it restarts once | No | Always on |
| [#8963](https://github.com/dsx-ai-factory/infra-controller/pull/8963) | Checks a host's BIOS and boot order again when its maintenance ends, before it can be allocated | No | `maintenance_end_boot_config_recheck_enabled = true` in `nico.yaml` |
| [libredfish#184](https://github.com/dsx-ai-factory/libredfish/pull/184) | Lenovo: skips the boot order change when the pending order already matches | No | Always on |
| [#8400](https://github.com/dsx-ai-factory/infra-controller/pull/8400) | GPU frequency from the max clock when `nvidia-smi` deprecates applications clocks | No | Always on |
| [#8957](https://github.com/dsx-ai-factory/infra-controller/pull/8957) | Machine validation tests on Lenovo ThinkSystem SR680a V3 | Yes. A NICo Core migration enables the tests | Always on |
| [#8960](https://github.com/dsx-ai-factory/infra-controller/pull/8960) | Drops the distrusted emSign roots from the REST images | No | Always on |
| [#9188](https://github.com/dsx-ai-factory/infra-controller/pull/9188) | NICo logs in to Vault on a Kubernetes auth mount other than `kubernetes` | No | `VAULT_KUBERNETES_AUTH_MOUNT` on `nico-api` |

`v2.4.0-rc.11.vcluster.5` adds, over `.4`:

- #8961, the BIOS drift re-apply.
- #8327 at its current PR head. A profile's `vendor` matches the BMC vendor, ignoring case. A Lenovo host with an AMI BMC keeps its `bios_profiles` entry.
- #9188 trims spaces and slashes around the auth mount name.
- #8955 shows the BIOS restart step in NICo's ManagedHost diagrams.

It has no database change.

These changes have no upstream PR yet:

- `maintenance_end_bios_reapply_enabled = true` in `nico.yaml` writes a host's BIOS profile again when its maintenance ends, restarts the host once and checks the result before it can be allocated. It runs on a `Ready` host without an instance; a host with an instance keeps its BIOS. A `bios-reapply` health alert keeps the host from being allocated until the BIOS write is issued. Each maintenance exit writes the BIOS once. Off by default. It includes the #8963 check.
- `full_lockdown_recovery_enabled = true` under `[machine_state_controller]` in `nico.yaml` also covers Lenovo XCC ThinkSystem SR680a V3. When a `Ready` host still has partial lockdown at the end of boot configuration, NICo applies the full lockdown, restarts the host and checks it before the host returns to `Ready`. Off by default. When off, such a host stays unavailable until a person locks it.
- A host firmware run that finds no firmware config for the host locks the host down again before it returns. Always on.

A database change is one-way. A NICo REST column stays after a downgrade. A NICo Core migration stops any build that doesn't ship it from migrating the database.

Our earlier builds on NICo `v2.4.0-rc.1` shipped NICo Core migrations 20261026003843, 20261026040000 and 20261102120000. This build drops them. A site that applied them removes those rows from `_sqlx_migrations` before it upgrades.

## vCluster Platform

The global Platform and each site's agent run `ghcr.io/loft-sh/vcluster-platform-experimental:5.0.0-rc.1-next.exp.8` on the stock `5.0.0-rc.1` chart. Both are in `versions.yaml`. For the stock build, set `image` to `ghcr.io/loft-sh/vcluster-platform:5.0.0-rc.1` and run the generator.

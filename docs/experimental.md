# Experimental

Our experimental NICo build, `v2.4.0-vcluster.19`, is NICo `v2.4.0-rc.1` plus the upstream PRs below, before NVIDIA merges them. The build in `versions.yaml` doesn't carry them.

| PR | Adds | Database change | Turn it on |
|---|---|---|---|
| [#7777](https://github.com/dsx-ai-factory/infra-controller/pull/7777) | `retainBmcCredentials` on REST expected machines: NICo keeps the BMC password instead of rotating it | Yes. NICo REST adds `expected_machine.retain_bmc_credentials` | `retainBmcCredentials: true` on the expected machine |
| [#8327](https://github.com/dsx-ai-factory/infra-controller/pull/8327) | Named BIOS profiles, picked per machine | No | `named_bios_profiles` in `nico.yaml`, and a `bios-profile=<name>` machine label |
| [#8244](https://github.com/dsx-ai-factory/infra-controller/pull/8244) | The BIOS step waits until the host boots again | No | Always on. The first DPU restart delay is off unless you set `dpu_first_restart_delay` under `[machine_state_controller]` |
| [#8953](https://github.com/dsx-ai-factory/infra-controller/pull/8953) | Waits instead of restarting the host when the BMC is busy during BIOS setup | No | Always on |
| [#8955](https://github.com/dsx-ai-factory/infra-controller/pull/8955) | Restarts the host for a BIOS change in its own step, so it restarts once | No | Always on |
| [libredfish#184](https://github.com/dsx-ai-factory/libredfish/pull/184) | Lenovo: skips the boot order change when the pending order already matches | No | Always on |
| [#8400](https://github.com/dsx-ai-factory/infra-controller/pull/8400) | GPU frequency from the max clock when `nvidia-smi` deprecates applications clocks | No | Always on |
| [#8957](https://github.com/dsx-ai-factory/infra-controller/pull/8957) | Machine validation tests on Lenovo ThinkSystem SR680a V3 | Yes. A NICo Core migration enables the tests | Always on |
| [#8960](https://github.com/dsx-ai-factory/infra-controller/pull/8960) | Drops the distrusted emSign roots from the REST images | No | Always on |

Two more changes have no upstream PR:

- `VAULT_KUBERNETES_AUTH_MOUNT` lets NICo log in to Vault on a Kubernetes auth mount other than `kubernetes`.
- Two NICo Core migrations from earlier builds, for BIOS observations and stored BIOS profiles, kept without code so a site that applied them can still upgrade.

A database change is one-way. A NICo REST column stays after a downgrade. A NICo Core migration stops any build that doesn't ship it from migrating the database.

# Firmware

Each site lists the firmware it wants in its NICo site config, in `overrides/nico.yaml`. NICo applies it. Git is the record.

## What goes where

| Component | Who updates it | When |
|---|---|---|
| Host BMC, UEFI | NICo, from `host_models` | Before onboarding, when `autoupdate = true` and the version is below `preingest_upgrade_when_below`. Later only on a `Ready` host with no tenant, inside a window an operator opens. |
| DPU BMC | NICo, from `dpu_config.dpu_models` | Before onboarding, when `autoupdate = true` and the BMC is below `BF-24.10-17`. NICo will not use DPF for a DPU with an older BMC. |
| DPU BMC, CEC, ATF, UEFI, NIC | DPF, from the BFB | On every DPU install or reinstall. Change the BFB to change them. |
| GPUs, NVSwitch, NVMe, PSU, other NICs | Nobody yet | Use the vendor's tools. |

## Rules

- Every component in `ordering` needs one `default` entry with `files = [{ url, sha256 }]`. NICo checks the sha256 after download. Don't use `url` and `checksum`: NICo ignores them on a host it already manages.
- Set `instance_updates_manual_tagging = true` and `explicit_start_needed = true` before you set `autoupdate = true`.
- `dpu_config.dpu_models` replaces NICo's built-in DPU list. Keep a BlueField-3 entry on DPF sites.
- NICo does not refuse a downgrade. Only raise versions.

`scripts/validate.sh` runs `scripts/check-firmware.py` on the examples. Run it on your own overrides with `python3 scripts/check-firmware.py clusters/*/nico/overrides/nico.yaml`.

## Serving the files

Vendors ship most firmware inside a zip. NICo needs the file itself, from a URL it can reach. Turn on the mirror in `overrides/site-prereqs.yaml`:

```yaml
firmwareMirror:
  enabled: true
  nodeSelector:
    kubernetes.io/hostname: <a site node>
  packages:
    - url: <vendor download URL>
      sha256: <the vendor's published sha256>
      file: <path inside the zip, empty for a plain file>
      fileSha256: <sha256 of that file>
```

The mirror downloads each package, checks both checksums and serves the file at `http://firmware-mirror.nico-system.svc.cluster.local/<file name>`. Use that URL and `fileSha256` in `files`.

## Start an update on one host

```
nico-admin-cli machine auto-update --machine <id> --enable
nico-admin-cli managed-host start-updates --machines <id>
```

Close it with `managed-host start-updates --machines <id> --cancel` and `machine auto-update --machine <id> --clear`.

## If an update fails

- The host leaves `Ready` and stays out. NICo retries every hour, 5 times.
- Closing the window does not bring it back.
- To stop, remove the model from `host_models`. NICo's next retry finds nothing to do and returns the host to `Ready`.
- A task the BMC reports as running is waited on with no time limit. Check the BMC's task if a host sits in `WaitingForFirmwareUpgrade` for hours.

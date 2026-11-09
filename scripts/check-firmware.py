import glob
import os
import re
import sys
import tomllib

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHA256 = re.compile(r"^[0-9a-f]{64}$")


def site_config(path):
    values = yaml.safe_load(open(path)) or {}
    text = ((values.get("nico-api") or {}).get("siteConfig") or {}).get("nicoApiSiteConfig")
    return tomllib.loads(text) if text else None


def has_artifact(entry):
    files = entry.get("files") or []
    return bool(files) and all(f.get("url") and SHA256.match(f.get("sha256") or "") for f in files)


def check_model(where, model):
    errors = []
    components = model.get("components") or {}
    ordering = model.get("ordering") or ["bmc", "uefi"]
    for name, component in components.items():
        try:
            re.compile(component.get("current_version_reported_as") or "")
        except re.error as e:
            errors.append(f"{where}.{name}: current_version_reported_as is not a regex: {e}")
        if component.get("preingest_upgrade_when_below") and name not in ordering:
            errors.append(f"{where}.{name}: has preingest_upgrade_when_below but is not in ordering")
    for name in ordering:
        component = components.get(name)
        if component is None:
            errors.append(f"{where}: ordering lists {name} but there is no such component")
            continue
        defaults = [e for e in component.get("known_firmware") or [] if e.get("default")]
        if len(defaults) != 1:
            errors.append(f"{where}.{name}: needs exactly one default known_firmware entry")
        elif not has_artifact(defaults[0]):
            errors.append(f"{where}.{name}: the default entry needs files = [{{ url, sha256 }}]. NICo ignores url and checksum on a host it already manages")
    return errors


def check(path):
    cfg = site_config(path)
    if cfg is None:
        return []
    errors = []
    hosts = cfg.get("host_models") or {}
    dpus = (cfg.get("dpu_config") or {}).get("dpu_models") or {}
    for key, model in hosts.items():
        errors += check_model(f"host_models.{key}", model)
    for key, model in dpus.items():
        errors += check_model(f"dpu_config.dpu_models.{key}", model)
    fw = cfg.get("firmware_global") or {}
    if hosts and fw.get("autoupdate"):
        if fw.get("instance_updates_manual_tagging") is not True:
            errors.append("firmware_global: set instance_updates_manual_tagging = true so updates never start on a tenant's host")
        for key, model in hosts.items():
            if not model.get("explicit_start_needed"):
                errors.append(f"host_models.{key}: set explicit_start_needed = true so a host updates only in a window an operator opens")
    if dpus and (cfg.get("dpf") or {}).get("enabled") and not any("bluefield 3" in str(m.get("model", "")).lower().replace("-", " ") for m in dpus.values()):
        errors.append("dpu_config.dpu_models replaces NICo's built-in DPU models, so a DPF site needs a BlueField-3 entry")
    return [f"{os.path.relpath(path, ROOT)}: {e}" for e in errors]


paths = sys.argv[1:] or sorted(glob.glob(f"{ROOT}/examples/customer-repo/clusters/*/nico/overrides/nico.yaml"))
errors = [e for p in paths for e in check(p)]
for e in errors:
    print(e)
print(f"{len(paths)} site configs checked, {len(errors)} firmware problems")
sys.exit(1 if errors else 0)

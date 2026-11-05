import os
import re
import sys
import yaml

R = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
V = yaml.safe_load(open(f"{R}/versions.yaml"))

GITOPS = {"kind": "GitRepository", "name": "vcluster-nico-gitops"}

def helm_repo(name, url, oci=False):
    spec = {"interval": "1h", "url": url}
    if oci:
        spec["type"] = "oci"
    return {"apiVersion": "source.toolkit.fluxcd.io/v1", "kind": "HelmRepository",
            "metadata": {"name": name, "namespace": "flux-system"}, "spec": spec}


REPOS = {
    "jetstack": "https://charts.jetstack.io",
    "loft": "https://charts.loft.sh",
    "argo": "https://argoproj.github.io/argo-helm",
    "nfd": "https://kubernetes-sigs.github.io/node-feature-discovery/charts",
    "doca": "https://helm.ngc.nvidia.com/nvidia/doca",
    "nvidia-charts": "oci://ghcr.io/nvidia/charts",
    "mellanox": "oci://ghcr.io/mellanox",
    "nico": "oci://ghcr.io/loft-sh/vcluster-platform-nico/charts",
    "hashicorp": "https://helm.releases.hashicorp.com",
    "redhat-cop": "https://redhat-cop.github.io/vault-config-operator",
}

NICO = V["nico"]["version"].lstrip("v")

CERT_MANAGER = dict(name="cert-manager", repo=("jetstack", "cert-manager", V["cert-manager"]), ns="cert-manager",
                    values={"crds": {"enabled": True}})

COMPONENTS = {
    "global": [
        CERT_MANAGER,
        dict(name="global-prereqs", gitops="./charts/global-prereqs", ns="nico-rest", deps=["cert-manager"],
             settings=[("storageClass", "postgres.storageClass")]),
        dict(name="temporal", repo=("nico", "temporal", NICO), ns="temporal", deps=["global-prereqs"], defaults=True,
             valuesFiles=["values.yaml", "values-kind.yaml"]),
        dict(name="temporal-namespaces", gitops="./charts/temporal-namespaces", ns="temporal", deps=["temporal"]),
        dict(name="nico-rest", repo=("nico", "nico-rest", NICO), ns="nico-rest", deps=["temporal-namespaces"], defaults=True,
             settings=[("platformOidcIssuer", "nico-rest-api.config.issuers[0].issuer"),
                       ("siteManagerHost", "nico-rest-site-manager.certificate.dnsNames[5]")]),
        dict(name="vcluster-platform", repo=("loft", "vcluster-platform", V["vcluster-platform"]), ns="vcluster-platform",
             deps=["cert-manager"], defaults=True, serverSideDiff=False,
             argoIgnore=[{"kind": "Service", "jqPathExpressions": [".spec.ports[].nodePort",
                                                                   '.metadata.annotations["metallb.io/ip-allocated-from-pool"]']},
                         {"kind": "PersistentVolumeClaim", "jsonPointers": ["/spec/storageClassName", "/spec/volumeName"]}], settings=[("platformHost", "config.loftHost")]),
        dict(name="nico-provider", gitops="./charts/nico-provider", ns="vcluster-platform",
             deps=["vcluster-platform", "nico-rest"], settings=[("nicoOrg", "org")]),
    ],
    "vault-config": [
        dict(name="vault-config-operator", repo=("redhat-cop", "vault-config-operator", V["vault-config-operator"]),
             ns="vault-config-operator", deps=["cert-manager"], defaults=True, crds="CreateReplace",
             settings=[("vaultAddr", "env[0].value")]),
        dict(name="vault-config", gitops="./charts/vault-config", ns="vault-config-operator", deps=["vault-config-operator"],
             settings=[("vaultAddr", "address"), ("vaultPrefix", "prefix"), ("vaultKvMount", "kvMount"),
                       ("vaultPkiMount", "pkiMount"), ("vaultPkiRole", "pkiRole"), ("vaultCertManagerAuthMount", "authMount"),
                       ("vaultCertManagerRole", "certManager.role"), ("vaultCaCommonName", "ca.commonName", True),
                       ("vaultCaKeyType", "ca.keyType", True), ("vaultCaKeyBits", "ca.keyBits", True),
                       ("vaultCaTtl", "ca.ttl", True), ("vaultCertTtl", "certTtl", True),
                       ("vaultStaticToken", "staticToken.enabled", True), ("vaultDpu", "dpu.enabled", True),
                       ("vaultGlobal", "global.enabled", True), ("vaultGlobalKubernetesHost", "global.kubernetesHost", True)]),
    ],
    "site-vault": [
        dict(name="vault", repo=("hashicorp", "vault", V["vault"]["chart"]), ns="vault", defaults=True, disableWait=True,
             settings=[("storageClass", "server.dataStorage.storageClass")]),
        dict(name="vault-unseal", gitops="./charts/vault-unseal", ns="vault", deps=["vault"],
             settings=[("vaultKvMount", "kvMount"), ("vaultPkiMount", "pki.mount"), ("vaultPkiRole", "pki.role"),
                       ("vaultCertManagerAuthMount", "certManager.authMount"), ("vaultCertManagerRole", "certManager.role")]),
    ],
    "site-base": [
        CERT_MANAGER,
        dict(name="site-prereqs", gitops="./charts/site-prereqs", ns="nico-system", deps=["cert-manager"],
             settings=[("vaultAddr", "vault.address"), ("vaultPkiMount", "vault.pkiMount"), ("vaultPkiRole", "vault.pkiRole"),
                       ("vaultCertManagerAuthMount", "vault.certManager.authMount"),
                       ("vaultCertManagerRole", "vault.certManager.role"), ("storageClass", "postgres.storageClass")]),
    ],
    "site-dpu": [
        dict(name="argo-cd", repo=("argo", "argo-cd", V["dpf"]["argo-cd"]), ns="dpf-operator-system", defaults=True),
        dict(name="kamaji", repo=("nvidia-charts", "kamaji", V["dpf"]["kamaji"]), ns="dpf-operator-system", deps=["cert-manager"],
             defaults=True, disableWait=True),
        dict(name="kamaji-datastore", gitops="./charts/kamaji-datastore", ns="dpf-operator-system", deps=["kamaji"],
             wave_with="kamaji"),
        dict(name="maintenance-operator", repo=("mellanox", "maintenance-operator-chart", V["dpf"]["maintenance-operator"]), ns="dpf-operator-system",
             deps=["cert-manager"], defaults=True),
        dict(name="node-feature-discovery", repo=("nfd", "node-feature-discovery", V["dpf"]["node-feature-discovery"]), ns="dpf-operator-system",
             defaults=True),
        dict(name="dpf-operator", repo=("doca", "dpf-operator", V["dpf"]["operator"]), ns="dpf-operator-system", defaults=True,
             deps=["argo-cd", "kamaji-datastore", "maintenance-operator", "node-feature-discovery"]),
        dict(name="dpf-config", gitops="./charts/dpf-config", ns="dpf-operator-system", deps=["dpf-operator"],
             settings=[("dpfApiServerVip", "apiServer.vip"), ("dpfApiServerPort", "apiServer.port"),
                       ("dpuClusterInterface", "dpuCluster.keepalived.interface"),
                       ("dpuClusterVip", "dpuCluster.keepalived.vip")]),
    ],
    "site": [
        dict(name="vcluster-platform-agent", repo=("loft", "vcluster-platform", V["vcluster-platform"]), ns="vcluster-platform",
             wave_with="nico-site-agent", defaults=True, disableWait=True),
        dict(name="nico", repo=("nico", "nico", NICO), ns="nico-system", deps=["site-prereqs"], defaults=True, timeout="20m",
             settings=[("vaultAddr", "nico-api.vaultClusterInfo.VAULT_SERVICE"),
                       ("vaultKvMount", "nico-api.vaultClusterInfo.NICO_VAULT_MOUNT"),
                       ("vaultPkiMount", "nico-api.vaultClusterInfo.NICO_VAULT_PKI_MOUNT")]),
        dict(name="nico-site-agent", release="nico-rest-site-agent", repo=("nico", "nico-rest-site-agent", NICO), ns="nico-rest",
             deps=["nico"], defaults=True, disableWait=True,
             argoIgnore=[{"kind": "Secret", "name": "temporal-client-site-agent-certs", "jsonPointers": ["/data"]}],
             settings=[("siteId", "envConfig.CLUSTER_ID"), ("siteId", "envConfig.TEMPORAL_SUBSCRIBE_NAMESPACE"),
                       ("temporalHost", "envConfig.TEMPORAL_HOST")]),
    ],
}

SCOPE_SOURCES = {"global": ["jetstack", "loft", "nico"], "vault-config": ["redhat-cop"], "site-vault": ["hashicorp"], "site-base": ["jetstack"],
                 "site-dpu": ["argo", "nvidia-charts", "mellanox", "nfd", "doca"], "site": ["loft", "nico"]}
SCOPE_TITLE = {"global": "global control plane", "vault-config": "NICo Vault configuration",
               "site-vault": "NICo site in-cluster Vault", "site-base": "NICo site base layer",
               "site-dpu": "NICo site DPU management layer", "site": "NICo site"}


def release(c):
    if "repo" in c:
        repo, chart, version = c["repo"]
        chart_spec = {"chart": chart, "version": version,
                      "sourceRef": {"kind": "HelmRepository", "name": repo}}
        if c.get("valuesFiles"):
            chart_spec["valuesFiles"] = c["valuesFiles"]
    else:
        chart_spec = {"chart": c["gitops"], "reconcileStrategy": "Revision", "sourceRef": dict(GITOPS)}
    values_from = []
    if c.get("defaults"):
        values_from.append({"kind": "ConfigMap", "name": f"gitops-defaults-{c['name']}", "valuesKey": "values.yaml"})
    for key, path, *optional in c.get("settings", []):
        ref = {"kind": "ConfigMap", "name": "gitops-settings", "valuesKey": key, "targetPath": path}
        if optional:
            ref["optional"] = True
        values_from.append(ref)
    values_from.append({"kind": "ConfigMap", "name": f"gitops-overrides-{c['name']}", "valuesKey": "values.yaml",
                        "optional": True})
    timeout = c.get("timeout", "15m")
    spec = {
        "interval": "10m",
        "releaseName": c.get("release", c["name"]),
        "targetNamespace": c["ns"],
        "storageNamespace": c["ns"],
        "chart": {"spec": chart_spec},
        "install": {"createNamespace": True, "timeout": timeout, "remediation": {"retries": 3}},
        "upgrade": {"timeout": timeout, "remediation": {"retries": 3}},
    }
    if c.get("crds"):
        spec["install"]["crds"] = c["crds"]
        spec["upgrade"]["crds"] = c["crds"]
    if c.get("disableWait"):
        spec["install"]["disableWait"] = True
        spec["upgrade"]["disableWait"] = True
    if c.get("deps"):
        spec["dependsOn"] = [{"name": d} for d in c["deps"]]
    if c.get("values"):
        spec["values"] = c["values"]
    spec["valuesFrom"] = values_from
    return {"apiVersion": "helm.toolkit.fluxcd.io/v2", "kind": "HelmRelease",
            "metadata": {"name": c["name"], "namespace": "flux-system"}, "spec": spec}


for scope in COMPONENTS:
    d = f"{R}/patterns/flux/{scope}"
    os.makedirs(d, exist_ok=True)
    sources = [helm_repo(n, REPOS[n], REPOS[n].startswith("oci://")) for n in SCOPE_SOURCES[scope]]
    with open(f"{d}/sources.yaml", "w") as f:
        yaml.safe_dump_all(sources, f, sort_keys=False)
    with open(f"{d}/releases.yaml", "w") as f:
        yaml.safe_dump_all([release(c) for c in COMPONENTS[scope]], f, sort_keys=False)
    with open(f"{d}/kustomization.yaml", "w") as f:
        resources = ["sources.yaml", "releases.yaml"]
        if any(c.get("defaults") for c in COMPONENTS[scope]):
            resources.append(f"../../../values/{scope}")
        yaml.safe_dump({"apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization",
                        "resources": resources}, f, sort_keys=False)
    print(scope, [c["name"] for c in COMPONENTS[scope]])

REPO_URLS = {k: v.replace("oci://", "") for k, v in REPOS.items()}


def argo_component(c, wave):
    out = {"name": c["name"], "releaseName": c.get("release", c["name"]), "namespace": c["ns"], "wave": wave,
           "serverSideDiff": c.get("serverSideDiff", True)}
    if c.get("argoIgnore"):
        out["ignoreDifferences"] = c["argoIgnore"]
    value_files = []
    if "repo" in c:
        repo, chart, version = c["repo"]
        out["source"] = {"repoURL": REPO_URLS[repo], "chart": chart, "targetRevision": version}
        value_files += c.get("valuesFiles", [])
    else:
        out["source"] = {"gitops": True, "path": c["gitops"].lstrip("./")}
    if c.get("defaults"):
        value_files.append(f"$gitops/values/{{scope}}/{c['name']}.yaml")
    value_files.append(f"$env/{{path}}/overrides/{c['name']}.yaml")
    out["valueFiles"] = value_files
    if c.get("settings"):
        out["settings"] = [dict({"key": k, "path": p}, **({"optional": True} if o else {})) for k, p, *o in c["settings"]]
    if c.get("values"):
        out["values"] = c["values"]
    return out


for scope in COMPONENTS:
    by_name = {c["name"]: c for c in COMPONENTS[scope]}
    deps = {c["name"]: [d for d in c.get("deps", []) if d in by_name] for c in COMPONENTS[scope]}
    wave = {}
    def depth(n):
        if n not in wave:
            if by_name[n].get("wave_with"):
                wave[n] = depth(by_name[n]["wave_with"])
            else:
                wave[n] = 0 if not deps[n] else 1 + max(depth(d) for d in deps[n])
        return wave[n]
    comps = []
    for c in COMPONENTS[scope]:
        a = argo_component(c, depth(c["name"]))
        a["valueFiles"] = [v.replace("{scope}", scope) for v in a["valueFiles"]]
        comps.append(a)
    values = {
        "gitops": {"repoURL": "https://github.com/example-org/vcluster-nico-gitops.git", "targetRevision": "v0.2.0"},
        "environment": {"repoURL": "https://github.com/example-org/nico-environments.git", "targetRevision": "main",
                        "path": f"clusters/{'global' if scope == 'global' else 'site-1'}/nico"},
        "argocd": {"namespace": "argocd", "project": "default"},
        "destination": {"server": "https://kubernetes.default.svc"},
        "namePrefix": "",
        "data": {},
        "ociRepositories": [REPO_URLS[n] for n in SCOPE_SOURCES[scope] if REPOS[n].startswith("oci://")],
        "components": comps,
    }
    os.makedirs(f"{R}/patterns/argocd/{scope}/templates", exist_ok=True)
    with open(f"{R}/patterns/argocd/{scope}/values.yaml", "w") as f:
        yaml.safe_dump(values, f, sort_keys=False)
    with open(f"{R}/patterns/argocd/{scope}/Chart.yaml", "w") as f:
        yaml.safe_dump({"apiVersion": "v2", "name": f"nico-{scope}-apps",
                        "description": f"Argo CD applications for the {SCOPE_TITLE[scope]}",
                        "type": "application", "version": "0.1.0", "appVersion": "2.4.0-rc.5"}, f, sort_keys=False)
    print("argocd", scope, [(c["name"], c["wave"]) for c in comps])

for scope in COMPONENTS:
    files = [c["name"] for c in COMPONENTS[scope] if c.get("defaults")]
    if not files:
        continue
    kust = {"apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization", "namespace": "flux-system",
            "generatorOptions": {"disableNameSuffixHash": True, "labels": {"reconcile.fluxcd.io/watch": "Enabled"}},
            "configMapGenerator": [{"name": f"gitops-defaults-{n}", "files": [f"values.yaml={n}.yaml"]} for n in files]}
    with open(f"{R}/values/{scope}/kustomization.yaml", "w") as f:
        yaml.safe_dump(kust, f, sort_keys=False)


def set_path(doc, path, value):
    node = doc
    for key in path[:-1]:
        node = node[key]
    node[path[-1]] = value


def pin(path, pins):
    doc = yaml.safe_load(open(f"{R}/{path}"))
    for keys, value in pins:
        set_path(doc, keys, value)
    with open(f"{R}/{path}", "w") as f:
        yaml.safe_dump(doc, f, sort_keys=False)


IMAGES = V["nico"]["version"]
pin("values/global/nico-rest.yaml", [(["global", "image", "tag"], IMAGES)])
pin("values/site/nico-site-agent.yaml", [(["global", "image", "tag"], IMAGES)])
site = yaml.safe_load(open(f"{R}/values/site/nico.yaml"))
pin("values/site/nico.yaml", [(["global", "image", "tag"], IMAGES)] +
    [(["nico-pxe", "bootArtifactContainers", i, "tag"], IMAGES) for i in range(len(site["nico-pxe"]["bootArtifactContainers"]))])
pin("values/site-dpu/dpf-operator.yaml", [(["controllerManager", "image", "tag"], V["dpf"]["operator"])])
pin("values/site-dpu/kamaji.yaml", [(["image", "tag"], V["dpf"]["kamaji-image"]), (["cfssl", "image", "tag"], V["dpf"]["cfssl"])])
pin("charts/global-prereqs/values.yaml", [(["postgres", "image"], f"postgres:{V['postgres']}")])
pin("charts/site-prereqs/values.yaml", [(["postgres", "image"], f"postgres:{V['postgres']}")])
pin("charts/temporal-namespaces/values.yaml", [(["adminToolsImage"], f"temporalio/admin-tools:{V['temporal-admin-tools']}")])
pin("charts/kamaji-datastore/values.yaml", [(["kubectlImage"], f"alpine/k8s:{V['kubectl']}")])
pin("charts/vault-unseal/values.yaml", [(["image"], f"alpine/k8s:{V['kubectl']}")])
pin("values/site-vault/vault.yaml", [(["server", "image", "tag"], V["vault"]["image"])])
with open(f"{R}/test/e2e/vault-dev.yaml") as f:
    dev = re.sub(r"hashicorp/vault:\S+", f"hashicorp/vault:{V['vault']['image']}", f.read())
with open(f"{R}/test/e2e/vault-dev.yaml", "w") as f:
    f.write(dev)

TOML_PINS = [(re.compile(r'(helm_version = ")[^"]*(")'), IMAGES.lstrip("v")),
             (re.compile(r'(docker_image_tag = ")[^"]*(")'), IMAGES)]
for root in ("examples/customer-repo/clusters", "test/e2e"):
    for dirpath, _, files in os.walk(f"{R}/{root}"):
        if "nico.yaml" in files and dirpath.endswith("overrides"):
            path = f"{dirpath}/nico.yaml"
            text = open(path).read()
            for rx, value in TOML_PINS:
                text = rx.sub(lambda m: m.group(1) + value + m.group(2), text)
            open(path, "w").write(text)

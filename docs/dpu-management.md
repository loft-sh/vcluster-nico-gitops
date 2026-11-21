# DPU management

The `site-dpu` layer installs DPF, which NICo uses to manage BlueField DPUs. All of it is public.

DPF's DPU cluster is a vCluster with private nodes. The global layer creates one per DPU site through the Platform.

## Turn it on

1. Run `scripts/bootstrap-site-secrets.sh` with `--dpu`.
2. Set the DPU keys in `settings.yaml`.
3. In `overrides/nico.yaml`, set `nico-api.dpf.rbacCreate: true` and `[dpf] enabled = true`. Copy the rest from the `site-dpu-1` example.
4. Install `site-dpu` before NICo first starts. The Flux example does this for you. With Argo CD, let `dpf-operator` and `dpf-config` go healthy first.
5. Connect the site to the Platform. See [site-onboarding.md](site-onboarding.md).
6. Add the site to the global `dpu-cluster.yaml` override:
   ```yaml
   sites:
     - cluster: site-dpu-1
       endpoint: 10.0.0.20
       addressPool: dpu-cluster
       dnsForwards:
         - zone: forge
           to: 10.0.0.53
   ```
   `cluster` is the site's cluster name in the Platform. `endpoint` is a free address in the MetalLB pool `addressPool`. `dnsForwards` is optional.

Choose `num_of_vfs` before onboarding DPUs. Changing it later reprovisions every DPU.

DPF uses the site BMC root credential from Vault at `<kv>/machines/bmc/site/root`.

## DPU cluster

| Item | Value |
|---|---|
| vCluster | `dpu-cluster-<cluster>` in the Platform project `default`, namespace `dpu-cluster` on the site |
| Versions | vCluster chart `0.38.0`, Kubernetes `v1.34.13`, from `versions.yaml` |
| API | `https://<endpoint>:443` |
| DPUCluster | `carbide-dpf-cluster`, type `static` |
| Kubeconfig | `dpf-operator-system/carbide-dpf-cluster-vcluster-admin`, key `super-admin.conf` |

- DPUs join with DPF's `kubeadm join` as private nodes.
- The vCluster exports its admin kubeconfig to `dpu-cluster/dpu-cluster-admin`. External Secrets copies it to the key DPF reads.
- The Platform creates the `dpu-cluster` namespace, with the Role that lets External Secrets read it.
- CoreDNS listens on `1053`, the port vCluster's kube-dns targets.
- Konnectivity is off. The API server reaches DPU kubelets on port `10250`, so logs and exec work.
- Auto-upgrade, flannel, local-path and the cloud controller are off. DPF installs flannel and multus.

## Move a Kamaji site to the vCluster

A DPUCluster's `spec.kubeconfig` can't change, and deleting a DPUCluster waits for its DPUs. DPU services deploy to every DPUCluster, so run one at a time.

1. Suspend the site's `nico-site-dpu`: `flux suspend kustomization nico-site-dpu`, or turn off auto-sync on `nico-site-dpu` in Argo CD.
2. Move the global layer to this release and add the site to `dpu-cluster.yaml`. Wait for `dpu-cluster/dpu-cluster-admin` on the site.
3. Force-delete or reprovision the site's hosts, so DPF releases their DPUs. Wait until `kubectl -n dpf-operator-system get dpus` is empty.
4. Delete the Kamaji DPUCluster while Kamaji's cluster manager still runs:
   ```bash
   kubectl -n dpf-operator-system delete dpucluster carbide-dpf-cluster
   ```
5. Move the site to this release, with the new DPU settings, and resume `nico-site-dpu`. It turns Kamaji off, copies the kubeconfig and applies the static DPUCluster.
6. The hosts onboard again. Their DPUs reinstall and join the vCluster.

Kamaji's CRDs, its `default` DataStore and its etcd volumes stay. Delete them once the DPUs have joined.

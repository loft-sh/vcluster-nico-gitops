# Checking it works

Global:
- Pods in `nico-rest`, `temporal` and `vcluster-platform` are Ready.
- `kubectl get nodeproviders.management.loft.sh` shows each site `Available`.

Site:
- Pods in `nico-system` are Ready.
- `kubectl -n nico-system logs deploy/nico-api | grep "refreshed vault token"` shows a login.
- The site agent stays up once `siteId` is set.

DPU site:
- `kubectl -n dpf-operator-system get externalsecret carbide-dpf-cluster-vcluster-admin` is `Ready`.
- `kubectl -n dpf-operator-system get dpucluster carbide-dpf-cluster` is `Ready`.

End to end: request a GPU node in a tenant cluster. It's ready in about 20 minutes. Deleting it wipes the machine.

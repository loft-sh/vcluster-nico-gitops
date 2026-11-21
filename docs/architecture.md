# Architecture

| Cluster | Runs |
|---|---|
| Global | vCluster Platform, NICo REST, Temporal, Postgres |
| Site | NICo Core, site agent, Postgres, and DPF and the DPU cluster on DPU sites |

## Connections

| From | To | Port |
|---|---|---|
| Platform | NICo REST | 8388, in cluster |
| Site agent | site manager on global | 8100 |
| Site agent | Temporal on global | 7233 |
| Site agent | NICo Core | 1079, in site |
| NICo Core | Vault | 8200 |
| Machines | NICo DHCP, DNS, PXE | site network |
| DPUs | DPU cluster endpoint | 443, site network |
| DPU cluster | DPU kubelets | 10250, site network |

Sites only connect out. The global cluster never connects into a site.

## Back up

The `nico` database on each site and `nico_rest` on global.

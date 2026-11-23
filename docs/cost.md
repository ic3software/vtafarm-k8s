# Cost

Monthly cost in `nbg1`, with the default settings. There are two bills: the management cluster
that runs Rancher, and each farm cluster that Rancher provisions.

## Management cluster (Rancher)

The three `cx23` servers run k3s and Rancher only. No farm workload runs on them.

| Item | Unit | Qty | / month |
| --- | --- | --- | --- |
| `cx23` (2 vCPU / 4 GB / 40 GB NVMe) | €6.59 | 3 | €19.77 |
| Load Balancer `lb11` | €8.99 | 1 | €8.99 |
| Public IPv4 | €0.60 | 3 | €1.80 |
| **Hetzner compute total** | | | **€30.56** |
| Hetzner Object Storage | €7.79 | 1 account | €7.79 |
| **Estimated total** | | | **€38.35** |

Two ways to scale:

- `cx33` (4 vCPU / 8 GB) costs about €11 per month more in total. It removes the memory
  pressure that `cx23` lives with. Do this first if Rancher gets OOMKilled.
- A fourth and a fifth server cost €13.18 per month. The cluster then survives two node
  failures at the same time instead of one.

## Farm cluster (RKE2)

The farm itself runs on a downstream RKE2 cluster, and every such cluster is billed on top of
the management cluster. It has the same shape: its nodes, one load balancer, and one public
IPv4 address per node. Two layouts have been run, both with three control plane nodes:

| Layout | Control plane | Workers | Machines | VTAs (approx.) | / month | Per VTA |
| --- | --- | --- | --- | --- | --- | --- |
| `cx33` farm | 3 | 3 | 6 | 175 | €73.73 | €0.42 |
| `cx43` farm | 3 | 1 | 4 | 350 | €88.15 | €0.25 |

The `cx43` farm hosts about twice as many VTAs on two fewer machines, for €14.42 per month
more. Starting from the three control plane nodes, the `cx33` farm needs three extra machines
to reach 175 VTAs, and the `cx43` farm needs one extra machine to reach 350.

The capacity doubles although the `cx43` farm has only a third more vCPU and RAM (32 vCPU and
64 GB against 24 vCPU and 48 GB). The reason is fixed overhead: the control plane, Vault,
PostgreSQL and the per-node system pods take the same memory on either farm before the first
VTA is scheduled, so the larger nodes leave about twice as much room for VTAs.

`cx33` farm, 6 machines, approximately 175 VTAs:

| Item | Unit | Qty | / month |
| --- | --- | --- | --- |
| `cx33` (4 vCPU / 8 GB / 80 GB NVMe) | €10.19 | 6 | €61.14 |
| Load Balancer `lb11` | €8.99 | 1 | €8.99 |
| Public IPv4 | €0.60 | 6 | €3.60 |
| **Estimated total per cluster** | | | **€73.73** |

`cx43` farm, 4 machines, approximately 350 VTAs:

| Item | Unit | Qty | / month |
| --- | --- | --- | --- |
| `cx43` (8 vCPU / 16 GB / 160 GB NVMe) | €19.19 | 4 | €76.76 |
| Load Balancer `lb11` | €8.99 | 1 | €8.99 |
| Public IPv4 | €0.60 | 4 | €2.40 |
| **Estimated total per cluster** | | | **€88.15** |

Each extra node adds one server and one IPv4 address: €10.79 per month for a `cx33`, €19.79
for a `cx43`. Both pools are billed while a cluster moves from one server type to the other;
see [RKE2 node pools](rke2-node-pools.md).

## Storage

### Longhorn: no extra cost

Stacks 01 to 05 add no storage line to the Hetzner bill. Longhorn uses the NVMe disks of the
farm nodes and does not attach Cloud Volumes, so the Vault, Vault transit and PostgreSQL PVCs
use disk space on machines that you already pay for. The cost is that each volume is stored
`longhorn_replica_count` times. This is why that count defaults to one. The management cluster
has no persistent volumes at all.

### Cloud Volumes: stack 06 only

Observability is the one stack that attaches Hetzner Cloud Volumes, through the
`hcloud-volumes` and `hcloud-volumes-retain` storage classes. With the template defaults, per
farm cluster:

| Volume | StorageClass | Size | / month |
| --- | --- | --- | --- |
| Prometheus TSDB | `hcloud-volumes-retain` | 20 GB | €1.37 |
| Thanos Compactor workspace | `hcloud-volumes` | 50 GB | €3.43 |
| Loki | `hcloud-volumes-retain` | 10 GB | €0.69 |
| **Volumes total per cluster** | | **80 GB** | **€5.49** |

This uses €0.0686 per GB per month. Hetzner does not publish the Volume rate on its public
pricing pages, so check it in the Console before relying on the figure. Each extra Prometheus
or Loki replica adds another Volume of the same size.

The two Thanos Store Gateway caches (3 GiB each) are on Longhorn and cost nothing extra.
Grafana has no persistent volume. Stack 06 also uses CPU and memory on the existing nodes for
Prometheus, Thanos, Loki, Alloy, Grafana, node-exporter and kube-state-metrics.

The Prometheus and Loki Volumes use the retained StorageClass. They keep billing after a stack
destroy until they are explicitly deleted.

### Object Storage: one base fee for every bucket

Hetzner bills Object Storage once per account, not per bucket. The €7.79 base fee in the
management table includes 1 TB of storage and 1 TB of egress across all buckets, and it is
charged in full from the first bucket, even an empty one. Every bucket in this deployment
shares that allowance:

| Bucket | Contents | Stack |
| --- | --- | --- |
| State and backup bucket | OpenTofu state and tfvars, etcd snapshots, Rancher backups | 01, 02 and every stack's backend |
| Longhorn backup bucket | Volume backups, 30 kept by default, when backups are enabled | 04 |
| Thanos bucket | 30 days of metric blocks | 06 |
| Loki bucket | 30 days of log chunks, plus ruler data | 06 |

These can be separate buckets or prefixes in a shared one; the bill is the same. Extra buckets
cost nothing while the total stays under 1 TB, which a deployment of this size does not come
close to. Above that, storage costs about €7.77 per TB per month and egress €1.20 per TB.
Traffic between the clusters and Object Storage inside `eu-central` is free.

## Whole deployment

One management cluster and one farm cluster, per month:

| Item | `cx33` farm | `cx43` farm |
| --- | --- | --- |
| Machines (3 management + farm) | 9 | 7 |
| vCPU (6 management + farm) | 6 + 24 = 30 | 6 + 32 = 38 |
| RAM (12 GB management + farm) | 12 + 48 = 60 GB | 12 + 64 = 76 GB |
| VTAs (approx.) | 175 | 350 |
| Management cluster compute | €30.56 | €30.56 |
| Farm cluster compute | €73.73 | €88.15 |
| Object Storage base fee | €7.79 | €7.79 |
| **Total without stack 06** | **€112.08** | **€126.50** |
| Observability Cloud Volumes | €5.49 | €5.49 |
| **Total with stack 06** | **€117.57** | **€131.99** |

All prices on this page include 20% VAT.

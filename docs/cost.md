# Cost

Monthly cost in `nbg1`, with the default settings:

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

This table covers the **management** cluster only. Every downstream RKE2 cluster is billed on
top of it, and it has the same shape: its server nodes (`cx33` by default, not `cx23`), one
load balancer, and one public IPv4 address per node.

Longhorn adds no line to the Hetzner bill. It uses the NVMe disks of the nodes and does not
attach Cloud Volumes, so the Vault PVCs use disk space on machines that you already pay for.
The cost is that each volume is stored `longhorn_replica_count` times. This is why that count
defaults to one. Hetzner Cloud Volumes are still available as the `hcloud-volumes` storage
class, for data that should be billed and attached separately.

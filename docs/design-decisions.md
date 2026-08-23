# Design decisions

This document explains why the repository is built this way. You do not need any of it to
deploy. Read it before you change one of these choices.

---

## The k3s management cluster

| Decision | Why |
| --- | --- |
| **3 servers with embedded etcd** | etcd needs a quorum of `(n/2)+1` nodes. The number of servers must therefore be odd, and at least 3. Three nodes survive one failure. |
| **k3s pinned to v1.35.7, Rancher to 2.14.3** | The Rancher chart declares a `kubeVersion` range, and helm enforces it: `2.14.x` requires `< 1.36.0-0`. The k3s `stable` channel is already on v1.36, so following that channel makes `helm install rancher` fail. v1.35.7 is the newest k3s that 2.14.3 accepts. |
| **API behind a load balancer (fixed registration address)** | Nodes join through `https://10.0.1.10:6443`. You can replace any server without touching the others, and your kubeconfig always uses the same address. |
| **One load balancer, three services** | A Hetzner load balancer supports up to 5 services and 10,000 connections at the same time. The only ingress traffic on a management cluster comes from a few administrators, so a second load balancer would add nothing. Ports :6443, :80 and :443 share one. The targets belong to the load balancer, and the health checks belong to each service. Every node runs both the API server and Traefik, so all three services are healthy. |
| **All k3s traffic on the private network** | Hetzner Cloud Firewalls filter the **public** interface only. They never inspect traffic inside the private network. etcd (2379-2380), the API (6443), the flannel VXLAN tunnel (8472) and the kubelet (10250) therefore listen on private IP addresses. The public interface exposes SSH only. |
| **Placement group `spread`** | Without it, Hetzner can put all three servers on the same physical host. One hardware failure would then destroy the etcd quorum. |
| **Hetzner cloud controller manager (CCM) manages nodes, OpenTofu manages load balancers** | The CCM sets `providerID` and the topology labels, and it handles the node lifecycle. Its load-balancer controller is disabled with `HCLOUD_LOAD_BALANCERS_ENABLED=false`. If it were enabled, it would create load balancers that OpenTofu does not know about. Those survive `tofu destroy`, and you keep paying for them. |
| **Traefik as a DaemonSet with hostPorts** | An external CCM requires `--disable-cloud-controller`. That flag also removes the built-in servicelb of k3s (klipper). Traefik therefore listens directly on `:80` and `:443` of each host, so that the load balancer has a target. |
| **IPv4 only on the nodes** | With one address family there is only one set of firewall rules to understand. Hetzner still gives the load balancer an IPv6 address and offers no option to disable it, but the load balancer reaches the nodes over private IPv4. |
| **`cx23` on x86, not the ARM64 `cax` line** | `cx23` gives 2 vCPU, 4 GB RAM and 40 GB NVMe on shared AMD EPYC. The memory is deliberately tight: k3s with etcd uses about 1 GB, one Rancher replica 1–1.5 GB, and the bundled add-ons about 0.5 GB. Watch for OOMKills during a Rancher upgrade, and move to `cx33` if you see them. The ARM64 `cax` line is cheaper, but [Rancher documents ARM64 as experimental and does not recommend it for production](https://ranchermanager.docs.rancher.com/how-to-guides/advanced-user-guides/enable-experimental-features/rancher-on-arm64). |

The HA topology follows the
[official k3s embedded-etcd HA guide](https://docs.k3s.io/datastore/ha-embedded): an odd number
of server nodes, where the first one starts with `--cluster-init` and the others join through a
**fixed registration address**. In this repository that address is a Hetzner Load Balancer.

---

## The platform on a downstream cluster

| Decision | Why |
| --- | --- |
| **A transit Vault for auto-unseal, not manual keys** | Without it, every restart of a Vault pod waits for a person to paste the unseal keys. The transit Vault is the start of the chain, so it is the only Vault that a person still unseals by hand. It holds no tenant data: if you lose it, you create new keys, but you do not lose the seeds. It gives you restarts without an operator. It does not protect a running cluster from an attacker, because the token that unwraps the root key of the farm lives in the same cluster. To use a cloud KMS instead, change the `seal` block. |
| **Longhorn owns the default StorageClass** | The RKE2 module installs hcloud-csi, so the cluster already has block storage: one replica, billed separately, and one volume attached to one node. Longhorn stores PVCs on the NVMe disks of the nodes, so Longhorn is the default class and `hcloud-volumes` is explicitly set to non-default. The default replica count is one, because the Raft protocol of Vault already keeps one copy per peer. Raise `longhorn_replica_count` for data that does not replicate itself. Two default classes are undefined behaviour: the API server picks one of them, and PVCs quietly land on the wrong storage. |

---

## Shared state

| Decision | Why |
| --- | --- |
| **State in the same bucket as the backups, not a second one** | The bucket already holds the etcd snapshots, which contain every Secret in the management cluster. State adds no exposure class that is not already there, and Hetzner S3 credentials are project-wide, so a second bucket could not be given a narrower key anyway. Prefixes keep the uses apart: everything OpenTofu owns sits under the `TF_PREFIX` folder from `.env`, beside the snapshot and backup folders. |
| **`use_lockfile` rather than a lock table or a lock server** | Hetzner Object Storage honours `If-None-Match: *`, so OpenTofu can hold the lock as an object beside the state. The DynamoDB table the S3 backend traditionally needed has no Hetzner equivalent, and any external lock service would be one more thing that has to be up before you can apply. |
| **Versioning paired with a 30-day retention rule** | Versioning is what makes a corrupted state recoverable. On its own it would also make the bucket grow forever, because k3s prunes etcd snapshots by deleting objects and a delete under versioning only hides one. The rule bounds that without shortening state history to anything useless. |
| **`backend.tf` tracked, but empty of site values** | A backend block cannot take variables, so hard-coding the bucket or a prefix would put one site's name in a tracked file and make the repository single-tenant. Bucket, region and key all arrive through `-backend-config`, and the endpoint and credentials through the environment — all of it from `.env`. The cost is that a bare `tofu init` cannot find the state on its own, which is why every init goes through `make`. |
| **`terraform.tfvars` through the bucket, not encrypted into Git** | Encrypting tfvars while the state and the etcd snapshots sit unencrypted in the same bucket would move no real boundary: the S3 credential already unlocks everything. Keeping tfvars out of Git also keeps the repository usable by anyone who points it at their own project. The trade is that tfvars have no review history — bucket versioning is the fallback. |

The full arrangement, including how a second operator joins, is in
[remote-state.md](remote-state.md).

---

## Repository layout

```text
.
├── Makefile                    # every common task is a make target
├── stacks/
│   ├── 01-infra/               # Hetzner resources + the k3s cluster
│   ├── 02-rancher/             # cert-manager + Rancher + backups + upgrade controller
│   ├── 03-rke2-clusters/
│   │   ├── _template/          # tracked template for downstream clusters
│   │   └── clusters/           # generated RKE2 roots (entire directory is gitignored)
│   ├── 04-vtafarm-platform/
│   │   ├── _template/          # tracked template for a cluster's platform layer
│   │   └── clusters/           # generated platform roots (also gitignored)
│   └── 05-vtafarm-app/
│       ├── _template/          # tracked template for the applications
│       └── clusters/           # generated app roots (also gitignored)
├── modules/
│   ├── rke2-custom-cluster/    # shared Rancher + Hetzner implementation
│   ├── vtafarm-platform/       # cert-manager + Longhorn + both Vaults
│   │   ├── charts/vault-pki/   # cert-manager Issuer + Certificate chain
│   │   └── templates/          # Vault chart values
│   └── vtafarm-app/            # the frontend and the API, from GHCR
│       └── charts/vtafarm-tls/ # ACME issuers, wildcard certificate, TLS store
├── scripts/
│   ├── fetch-kubeconfig.sh     # pull the kubeconfig and rewrite its API endpoint
│   ├── merge-kubeconfig.sh     # merge it into ~/.kube/config
│   ├── delete-kube-context.sh  # remove it from ~/.kube/config
│   ├── etcd-snapshot.sh        # take / list etcd snapshots
│   ├── state-bucket-setup.sh   # versioning + retention on the state bucket
│   ├── tfvars-sync.sh          # move terraform.tfvars to and from the bucket
│   ├── drop-state.sh           # delete one stack's state after its cluster is gone
│   └── vault-bootstrap.sh      # one-time Vault configuration, per cluster
└── docs/                       # the runbooks, indexed at the end of the README
```

---

## Why five stacks

OpenTofu configures every provider *before* it starts to run. The `helm` and `kubernetes`
providers need a kubeconfig, and that file exists only after stack 01 has finished. If both
were in one stack, the stack could not run at all. They are therefore separate: stack 01 builds
the cluster and writes the kubeconfig, and stack 02 reads it. This is the standard pattern.

The same reason applies twice more, one layer lower. Rancher must be running before its
provider can create a custom cluster and return the node registration command. That is
stack 03. The cluster must then be Active and return a kubeconfig before anything can be
installed into it. That is stack 04.

Stacks 03, 04 and 05 keep one directory per cluster, under `clusters/<name>`, and each
directory has its own state file. Creating or destroying one cluster therefore cannot affect
another. The shared logic lives in `modules/`, which is tracked in Git. Git ignores the
generated `clusters/` directories, because they are site-specific: a second operator recreates
them from `_template` with `make new-…` and then pulls their `terraform.tfvars` from the
bucket. The directory name of a cluster is the single source of truth in every stack. It is
also how stack 04 finds the kubeconfig that stack 03 wrote for the same name.

---

## References

- [k3s — High Availability with Embedded etcd](https://docs.k3s.io/datastore/ha-embedded)
- [k3s — Fixed Registration Address](https://docs.k3s.io/datastore/ha)
- [k3s — Networking Requirements](https://docs.k3s.io/installation/requirements)
- [k3s — etcd Snapshot CLI](https://docs.k3s.io/cli/etcd-snapshot)
- [k3s — Automated Upgrades](https://docs.k3s.io/upgrades/automated)
- [Rancher — Install on a Kubernetes Cluster](https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/install-upgrade-on-a-kubernetes-cluster)
- [Rancher — Support Matrix](https://www.suse.com/suse-rancher/support-matrix/all-supported-versions/)
- [Hetzner Cloud provider](https://search.opentofu.org/provider/hetznercloud/hcloud/latest)
- [hcloud-cloud-controller-manager](https://github.com/hetznercloud/hcloud-cloud-controller-manager)

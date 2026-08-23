# Day-2 operations

Every common task is a `make` target. Run `make help` to list them all.

## The k3s management cluster

```bash
make help                # list every target
make status              # cluster health overview
make outputs             # LB IPs, node IPs, DNS records to create
make ssh                 # SSH into the first control-plane node
make token               # the k3s token
make rancher-password    # Rancher bootstrap password
make snapshot            # on-demand etcd snapshot
make snapshots           # list snapshots
make upgrade-packages    # apt upgrade every node, one at a time
make kubeconfig          # re-fetch the kubeconfig
make kubeconfig-merge    # merge it into ~/.kube/config as a switchable context
make kubeconfig-delete   # delete it from ~/.kube/config
```

## A downstream cluster

Every target takes `CLUSTER=<name>`:

```bash
make kubeconfig-rke2       CLUSTER=rke2-vtafarm-production   # write its kubeconfig.yaml
make kubeconfig-merge-rke2 CLUSTER=rke2-vtafarm-production   # and merge it into ~/.kube/config
make refresh-rke2          CLUSTER=rke2-vtafarm-production   # re-read Rancher state
make outputs-rke2          CLUSTER=rke2-vtafarm-production   # LB IP, node IPs

make apply-vtafarm-platform   CLUSTER=rke2-vtafarm-production   # cert-manager, Longhorn, Vault
make outputs-vtafarm-platform CLUSTER=rke2-vtafarm-production   # the in-cluster Vault address
make vault-status             CLUSTER=rke2-vtafarm-production   # Vault, Longhorn and certificates
make vault-bootstrap          CLUSTER=rke2-vtafarm-production TARGET=farm

make apply-vtafarm-app   CLUSTER=rke2-vtafarm-production   # the frontend and the API
make outputs-vtafarm-app CLUSTER=rke2-vtafarm-production   # the URLs and the DNS records
```

The destroy targets are in [teardown.md](teardown.md).

---

## Kubeconfig contexts

```bash
make kubeconfig-merge                                        # k3s cluster → ~/.kube/config
make kubeconfig-merge-rke2 CLUSTER=rke2-vtafarm-production   # a downstream cluster
make kubeconfig-delete                                       # remove the k3s context again
make kubeconfig-delete CLUSTER=rke2-vtafarm-production       # remove a downstream context
```

The merge first backs up `~/.kube/config`. It does not change your other clusters and it does
not change your current context. You can run it as often as you like: entries with the same
name are replaced, not duplicated. If you rebuild a cluster and run it again, it simply updates
the credentials. The context uses the cluster name.

Rancher also generates one context per control-plane server. `kubeconfig-rke2` keeps only the
current-cluster context from Rancher, so kubectl shows one entry per cluster instead of one
entry per server.

The delete target also makes a backup first, and it keeps the cluster and user entries that
other contexts still use. It changes nothing in Rancher or Hetzner.

---

## Adding nodes to the k3s cluster

Every node is both a control-plane node and an etcd member, so you scale the cluster by adding
servers. The number of servers must stay **odd**, because etcd needs a quorum. With 5 servers
instead of 3, the cluster survives two failures at the same time instead of one:

```hcl
# stacks/01-infra/terraform.tfvars
server_count = 5
```

```bash
make snapshot        # etcd membership changes; have a restore point first
make apply
kubectl get nodes -w
```

The new nodes wait for the existing ones and then join through the load balancer. They are
added to the firewall and to the load balancer targets by label. You do not have to change
anything else.

> This repository has no separate worker pool. That is deliberate: when every node can run
> workloads, there is only one type of node to think about. If the workloads outgrow that, add
> a second `hcloud_server` resource with `INSTALL_K3S_EXEC=agent` in its bootstrap environment,
> and add an `agent-plan` for the upgrade controller.

---

## Backups at a glance

There are two layers. Both are configured, and one cannot replace the other:

| Layer | Tool | Covers | Use when |
| --- | --- | --- | --- |
| **etcd snapshot** | built into k3s | the whole Kubernetes datastore, which includes every resource and all of Rancher | the cluster is broken, someone deleted something by mistake, or you need to go back to an earlier state |
| **Rancher backup** | rancher-backup operator | only Rancher's own CRDs, users and downstream cluster registrations | migrating Rancher to a different cluster |

Both upload to the same private Hetzner Object Storage bucket on a schedule, under different
folder prefixes. etcd takes a snapshot every **6 hours** by default. Each node keeps 12
compressed snapshots on disk, which is 3 days. The three nodes share a limit of 360 snapshots
in S3, which is about 30 days. You change these numbers with the `etcd_snapshot_*` and
`etcd_s3_*` variables in `stacks/01-infra/terraform.tfvars`.

```bash
make snapshots            # list all snapshots (local + S3)
make snapshot             # take one right now
```

[backup-restore.md](backup-restore.md) covers retention, the three things you must store
outside the cluster, the restore procedures and the drill.

A third thing shares the bucket: everything OpenTofu owns, under the `TF_PREFIX` folder set in
`.env` — state in `tfstate/`, the `terraform.tfvars` in `tfvars/`. State is versioned rather than
snapshotted, and it is not part of either layer above.

| Target | Does |
| --- | --- |
| `make tfvars-diff` | Names the variables that differ from the bucket, never their values |
| `make tfvars-pull` | Overwrites every local `terraform.tfvars` with the bucket's copy |
| `make tfvars-push` | Uploads yours, after showing the same report and asking |

[remote-state.md](remote-state.md) covers locking, recovery and how a second operator joins.

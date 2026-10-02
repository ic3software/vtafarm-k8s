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
make kubeconfig-rke2       CLUSTER=rke2-vtafarm-staging   # validate/write its kubeconfig.yaml
make kubeconfig-merge-rke2 CLUSTER=rke2-vtafarm-staging   # merge it into ~/.kube/config
make kubeconfig-check-rke2 CLUSTER=rke2-vtafarm-staging   # check the local token and direct access
make kubeconfig-renew-rke2 CLUSTER=rke2-vtafarm-staging   # request and validate fresh credentials
make kubeconfig-test-rke2  CLUSTER=rke2-vtafarm-staging   # test a temporary token, then delete it
make refresh-rke2         CLUSTER=rke2-vtafarm-staging   # refresh infrastructure state
make outputs-rke2         CLUSTER=rke2-vtafarm-staging   # LB IP, node IPs

make apply-vtafarm-platform   CLUSTER=rke2-vtafarm-production   # cert-manager, Longhorn, Vault
make outputs-vtafarm-platform CLUSTER=rke2-vtafarm-production   # the in-cluster Vault address
make vault-status             CLUSTER=rke2-vtafarm-production   # Vault, Longhorn and certificates
make vault-bootstrap          CLUSTER=rke2-vtafarm-production TARGET=farm

make apply-vtafarm-app   CLUSTER=rke2-vtafarm-production   # the frontend and the API
make outputs-vtafarm-app CLUSTER=rke2-vtafarm-production   # the URLs and the DNS records
```

The destroy targets are in [teardown.md](teardown.md).

### Scale down nodes

Reduce `server_count` or `worker_count`, then run `make apply-rke2 CLUSTER=<name>`.
The Make target saves an OpenTofu plan and asks for `yes` before starting retirement or apply.
It executes that same saved plan only after retirement succeeds. No separate cleanup command is needed.
The workflow requires the management kubeconfig at `stacks/01-infra/kubeconfig.yaml` and that
downstream cluster's `kubeconfig.yaml`, including permission to exec into a surviving etcd pod.

Before deleting any VM, the workflow validates Rancher ownership, VM identities and Ready
remaining nodes. It cordons all retiring nodes and disables their Longhorn scheduling so data
cannot move to another retiring node. It then processes each node sequentially:

1. Request Longhorn eviction and wait up to 30 minutes for replicas and backing images to leave.
2. Drain workloads, respecting PodDisruptionBudgets and protecting emptyDir data and unmanaged Pods.
3. Wait for Longhorn volumes, engines and CSI VolumeAttachments to detach.
4. Delete the Rancher Machine using normal finalizers; Rancher's etcd hook handles server retirement.
5. Confirm the Kubernetes Node is gone, its etcd membership is removed, and etcd becomes healthy
   within five minutes.

Longhorn volumes must be healthy and the remaining nodes need enough disk space and eligible
disks for rebuilding. Increasing node count does not increase each volume's replica count.
A failed step prevents the saved VM plan from executing. Eviction, cordon or Rancher retirement
already completed are not rolled back: inspect the reported dependency and rerun the same Make
command after fixing it. Workloads may restart during draining; uninterrupted service depends
on their replication, capacity and disruption budgets.

Apply new nodes before retiring old ones in a separate run. Mixed growth and shrinkage, VM
replacements, reductions below three servers, and unrelated infrastructure changes during
retirement are rejected. Do not run concurrent applies from other checkouts or hosts. The
workflow checks state freshness between retirements, but does not hold the backend lock across
the Kubernetes operations. A local `.rke2-apply-lock` prevents overlapping runs in one cluster
directory; inspect any surviving process before removing a lock left by an abrupt interruption.

**Direct `tofu apply` bypasses the pre-retirement workflow.** Use the Make target for count reductions.
The module's post-apply reconciliation remains for orphaned Rancher and Longhorn metadata.
It removes records only when retiring Nodes are gone, desired Nodes are Ready, and storage no
longer references the node or its disks. UID/resource-version preconditions and normal finalizers
protect deletions. VM changes completed before a post-apply cleanup failure remain applied.

---

## Kubeconfig contexts

```bash
make kubeconfig-merge                                    # k3s cluster → ~/.kube/config
make kubeconfig-merge-rke2 CLUSTER=rke2-vtafarm-staging    # a downstream cluster
make kubeconfig-delete                                   # remove the k3s context
make kubeconfig-delete CLUSTER=rke2-vtafarm-staging      # remove a downstream context
```

The merge builds a temporary config, backs up an existing `~/.kube/config`, then replaces it
atomically. It preserves your other clusters and current context. Same-named entries are replaced,
not duplicated. The context uses the cluster name. After rebuilding an RKE2 cluster, run
`kubeconfig-renew-rke2` before merging so the endpoint, CA and credentials are updated together.

Rancher also generates contexts for individual control-plane servers. `kubeconfig-rke2` uses
an authorized cluster endpoint's CA and its referenced user token, and points it at the
cluster's API endpoint from state. This bypasses Rancher's proxy rate limits.

If the local file is missing, `kubeconfig-rke2` initially reads it from OpenTofu state.
Otherwise, it validates the existing file without replacing it. Merge runs this validation
first, so it preserves locally renewed credentials. `refresh-rke2` updates infrastructure
state and does not guarantee a new token.

The delete target also makes a backup first, and it keeps the cluster and user entries that
other contexts still use. It changes nothing in Rancher or Hetzner.

### Renewing credentials

These commands require Bash, `curl`, `jq`, `kubectl`, initialized OpenTofu state, the state
credentials in `.env`, and a valid `rancher_token_key` in the cluster's `terraform.tfvars`.
The Rancher API credential must be able to create and delete kubeconfigs and read token metadata
for that user. It is separate from the expiring token in the downloaded kubeconfig.
`rancher_insecure` retains its existing meaning for Rancher API TLS verification;
direct cluster TLS is always verified.

To request fresh credentials, even before the current token expires, and merge them:

```bash
make kubeconfig-renew-rke2 CLUSTER=rke2-vtafarm-staging &&
make kubeconfig-merge-rke2 CLUSTER=rke2-vtafarm-staging
```

Renewal uses Rancher's [Kubeconfig API][kubeconfig-api] rather than the provider's cached
`kube_config` output. It uses Rancher's default lifetime unless `TTL=<seconds>` is supplied.
The lifetime must fit the server's `kubeconfig-default-token-ttl-minutes` limit. `AUTH_WAIT`
controls how long to retry direct authentication failures: 60 seconds by default, from 0 to
300 seconds. An in-flight request may finish after that window.

Renewal validates token scope, expiry and direct `get nodes` access before writing YAML.
It backs up the previous file alongside it; both files have mode `0600`. If validation fails,
the candidate and its tokens are deleted from Rancher, and existing local and merged files
remain intact.
If cleanup itself fails, the error identifies the Rancher Kubeconfig resource to delete.

Successful renewal prints the Rancher Kubeconfig resource name, which can be used for later
revocation. Older credentials are not automatically revoked because other clients may still
use them. Manage these resources through an authenticated Rancher Kubernetes API context;
deleting a Kubeconfig also deletes its backing tokens.

Renewal does not update the `kube_config` output in OpenTofu state. Use the local file or merged
context for cluster operations. Keep the cluster directory and its configuration; if only
`kubeconfig.yaml` is deleted, run renewal to obtain fresh credentials.

To check the local cluster file without renewing it (this does not check `~/.kube/config`):

```bash
make kubeconfig-check-rke2 CLUSTER=rke2-vtafarm-staging
```

### Testing a new token without replacing the working one

```bash
# Create a 10-minute candidate, test direct access, then delete it even on failure.
make kubeconfig-test-rke2 CLUSTER=rke2-vtafarm-staging

# Optional shorter wait while investigating a known synchronization failure.
make kubeconfig-test-rke2 CLUSTER=rke2-vtafarm-staging TTL=600 AUTH_WAIT=15

# Offline regression tests: no credentials or live cluster required.
make test-kubeconfig
```

The live test checks a separate temporary token and leaves the existing kubeconfig intact.
If Rancher's proxy accepts the token but direct access fails, investigate `ClusterAuthToken`
synchronization. The command reports the failure; repeating merge does not repair it.
See [authentication troubleshooting](troubleshooting.md#rke2-kubectl-returns-unauthorized).

[kubeconfig-api]: https://ranchermanager.docs.rancher.com/v2.14/api/workflows/kubeconfigs

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

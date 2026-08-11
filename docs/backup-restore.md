# Backup and Disaster Recovery Runbook

> **A backup you have never restored is not a backup.** The last section is a drill — run it
> once before you rely on this cluster.

---

## 1. What is being backed up

| Layer | By | Contents | Frequency | Destination |
| --- | --- | --- | --- | --- |
| etcd snapshot | k3s built-in | the whole Kubernetes datastore | every 6h, on each server | 12 per server locally (3 days) + 360 in DigitalOcean Spaces (30 days) |
| Rancher backup | rancher-backup operator | Rancher CRDs, users, downstream cluster registrations | daily 03:00 | 30 in DigitalOcean Spaces |

Configured in:

- etcd: `etcd_snapshot_*` / `etcd_s3_*` in `stacks/01-infra/terraform.tfvars`
- Rancher: `rancher_backup_*` / `backup_s3_*` in `stacks/02-platform/terraform.tfvars`

---

## 2. Three things you must store outside the cluster

The snapshot files alone will **not** get you a cluster back. Keep these in a password manager
or a separate backup location.

### (a) The k3s token

```bash
make token
```

This token encrypts the bootstrap data inside etcd. **Without it a snapshot cannot be
decrypted.**

### (b) Terraform state

```text
stacks/01-infra/terraform.tfstate
stacks/02-platform/terraform.tfstate
```

Lose it and Terraform forgets everything it built; the next apply tries to recreate the world.

Consider a remote backend (add `backend "s3"` to `versions.tf`), or at minimum copy it
regularly:

```bash
s3cmd put stacks/*/terraform.tfstate s3://your-space/tfstate/
```

### (c) The S3 credentials

The DigitalOcean Spaces access key and secret. If they only live in a `terraform.tfvars` that
gets lost, so do the backups you carefully took.

---

## 3. Verify backups are actually running

```bash
make snapshots
```

Confirm:

- the newest entry matches the schedule (within the last 6 hours)
- the `LOCATION` column contains `s3://` entries, meaning the upload really succeeded
- all three servers appear — each one snapshots independently and stamps its own name into
  the filename, so `etcd-snapshot-<node>-<timestamp>` should show up three times per cycle

Or read it from the source:

```bash
ssh root@<server-1> 'journalctl -u k3s | grep -i "etcd-snapshot\|s3" | tail -20'
```

Rancher backups:

```bash
kubectl get backup
kubectl describe backup rancher-scheduled-backup | tail -20
```

---

## 4. On-demand snapshot

Take one before anything risky — upgrades, CustomResourceDefinition (CRD) changes, bulk deletions:

```bash
make snapshot
# or with a name you will recognise later
./scripts/etcd-snapshot.sh save before-rancher-upgrade
```

---

## 5. Scenario A — a single node died

**No backup needed.** etcd still has quorum (1 of 3 lost), the cluster keeps serving. Just
replace the node.

```bash
# 1. remove it from Kubernetes
kubectl delete node rancher-ha-server-2

# 2. confirm the remaining cluster is healthy
kubectl get nodes
ssh root@<healthy-node> 'k3s kubectl get --raw "/healthz?verbose"' | grep etcd

# 3. rebuild that one server
terraform -chdir=stacks/01-infra apply -replace='hcloud_server.server[1]'
```

The replacement boots, waits for the load balancer to be serving, and joins by itself.

```bash
kubectl get nodes -w
```

> **Why index `[1]`?** Terraform's `count` is zero-based, so `server-2` is
> `hcloud_server.server[1]`.

---

## 6. Scenario B — etcd lost quorum (two or more servers down)

The API server stops responding entirely. Reset the cluster down to a single etcd member, then
let the others rejoin.

On **all** surviving servers:

```bash
ssh root@<each-server> 'systemctl stop k3s'
```

On **one** of them (pick the most up-to-date, usually server-1):

```bash
ssh root@<server-1>
k3s server --cluster-reset
```

Wait for:

```text
Managed etcd cluster membership has been reset, restart without --cluster-reset flag now.
```

Press Ctrl-C, then:

```bash
systemctl start k3s
```

On **every other** server:

```bash
systemctl stop k3s
rm -rf /var/lib/rancher/k3s/server/db/
systemctl start k3s
```

They rejoin as fresh members.

```bash
kubectl get nodes
```

---

## 7. Scenario C — full restore from a snapshot

For accidental deletion, a failed upgrade, or rebuilding the cluster. This follows the
[k3s etcd-snapshot documentation](https://docs.k3s.io/cli/etcd-snapshot).

### Step 1 — find the snapshot

```bash
make snapshots
```

Note the filename, e.g. `etcd-snapshot-rancher-ha-server-1-1754812800`.

### Step 2 — stop k3s everywhere

```bash
for ip in <server-1> <server-2> <server-3>; do
  ssh root@$ip 'systemctl stop k3s'
done
```

### Step 3 — restore on server-1

From a local snapshot:

```bash
ssh root@<server-1>
k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<snapshot-file>
```

From S3 — pass only the **filename**, not a path:

```bash
ssh root@<server-1>
k3s server \
  --cluster-reset \
  --etcd-s3 \
  --cluster-reset-restore-path=<snapshot-file>
```

> The S3 endpoint, bucket and credentials are already in `/etc/rancher/k3s/config.yaml`, and so
> is the token — k3s reads them, so there is no need to repeat them on the command line.
>
> **Restoring onto a brand-new host** (whose config.yaml does not yet hold the original token)
> requires all of them explicitly:
>
> ```bash
> k3s server --cluster-reset --etcd-s3 \
>   --cluster-reset-restore-path=<snapshot-file> \
>   --etcd-s3-endpoint=fra1.digitaloceanspaces.com \
>   --etcd-s3-region=fra1 \
>   --etcd-s3-bucket=<bucket> \
>   --etcd-s3-access-key=<key> \
>   --etcd-s3-secret-key=<secret> \
>   --token=<the k3s token you saved>
> ```
>
> The token decrypts the bootstrap data inside the snapshot. **A wrong token fails outright.**

Wait for `Managed etcd cluster membership has been reset...`, press Ctrl-C, then:

```bash
systemctl start k3s
```

### Step 4 — rejoin the other servers

```bash
for ip in <server-2> <server-3>; do
  ssh root@$ip 'rm -rf /var/lib/rancher/k3s/server/db/ && systemctl start k3s'
done
```

### Step 5 — verify

```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes
kubectl get pods -A
kubectl -n cattle-system get pods
```

---

## 8. Scenario D — the entire Hetzner project is gone

Worst case: all you have left is the S3 snapshots, the k3s token, and this git repo.

```bash
# 1. Rebuild infrastructure with a single server first
#    (temporarily set server_count = 1 in stacks/01-infra/terraform.tfvars)
terraform -chdir=stacks/01-infra apply

# 2. Restore onto the new server-1 — the --token flag is mandatory here
ssh root@<new server-1>
systemctl stop k3s
k3s server --cluster-reset --etcd-s3 \
  --cluster-reset-restore-path=<snapshot-file> \
  --etcd-s3-endpoint=fra1.digitaloceanspaces.com \
  --etcd-s3-region=fra1 \
  --etcd-s3-bucket=<bucket> \
  --etcd-s3-access-key=<key> \
  --etcd-s3-secret-key=<secret> \
  --token=<the original k3s token>
# wait for the message → Ctrl-C → systemctl start k3s

# 3. Set server_count back to 3 and apply so the other two join
terraform -chdir=stacks/01-infra apply
```

> ⚠️ **Token mismatch is the trap here.** A fresh `terraform apply` generates a *new*
> `random_password.k3s_token`, but the restored cluster runs on the *old* token from the
> snapshot. New nodes would be handed the new token and fail to join.
>
> If this scenario is part of your threat model, replace `random_password.k3s_token` in
> `stacks/01-infra/network.tf` with a fixed value supplied through a variable, and keep that
> value in your password manager.

---

## 9. The drill — run this once

On a **throwaway cluster**. Takes about 20 minutes.

```bash
# 1. leave a marker
kubectl create namespace restore-drill
kubectl -n restore-drill create configmap marker --from-literal=created="$(date -Is)"

# 2. snapshot it
./scripts/etcd-snapshot.sh save drill-$(date +%Y%m%d)
make snapshots        # confirm it reached S3

# 3. cause the "disaster"
kubectl delete namespace restore-drill

# 4. restore following Scenario C above

# 5. prove the data came back
kubectl -n restore-drill get configmap marker -o yaml
```

Seeing the marker return means your backups genuinely work.

**Also write down how long it took.** That number is your real Recovery Time Objective (RTO).

---

## 10. Common problems

### Snapshots are not reaching S3

```bash
ssh root@<server-1> 'journalctl -u k3s | grep -i s3 | tail -30'
```

- `NoSuchBucket` / 404 → wrong bucket or region; try setting
  `etcd_s3_bucket_lookup_type = "path"` in `stacks/01-infra/terraform.tfvars`
- `SignatureDoesNotMatch` → wrong access key or secret key
- `no such host` → bad endpoint (no `https://` prefix, and no bucket name in it)

Note that fixing tfvars and running `make apply` will **not** push the change to running nodes —
`user_data` is protected by `ignore_changes` (see the README). Either edit
`/etc/rancher/k3s/config.yaml` on each node and `systemctl restart k3s`, or roll the nodes one
at a time with `-replace`.

### Rancher is missing or crash-looping after `--cluster-reset`

Rancher's state lives in etcd, so a successful restore brings it back. Give it five minutes,
then check `kubectl -n cattle-system logs -l app=rancher --tail=100`.

### Can I restore just one namespace?

No — an etcd snapshot is all-or-nothing. For granular recovery install Velero, or use the
Rancher backup operator, which restores Rancher-scoped resources only.

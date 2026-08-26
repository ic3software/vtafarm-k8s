# Backup and Restore

> **A backup you have never restored is not a backup.** Section 5 is how you find out.

Three layers back themselves up independently, all into the same Hetzner bucket. Each covers
something the other two do not.

| Layer | Holds | Restores |
| --- | --- | --- |
| **etcd** | the management cluster's whole datastore, Rancher included | the whole cluster, to a point in time |
| **Rancher** | Rancher's own state: users, roles, cluster registrations | Rancher, onto any cluster |
| **Longhorn** | the farm's data, one backup per volume | one volume at a time |

Schedules and retention are set in `terraform.tfvars` and summarised in
[operations.md](operations.md). This document is about doing it by hand, undoing it by hand, and
proving both work.

---

## 1. Keep these outside the cluster

The bucket holds the OpenTofu state as well as the backups, so it already holds the k3s token.
What it cannot hold is the way in:

| | Lives in |
| --- | --- |
| the S3 access key and secret key | `.env` and `terraform.tfvars` |
| the Hetzner API token and your SSH key | `stacks/01-infra/terraform.tfvars`, `~/.ssh` |
| `vault-init-transit.json`, `vault-init-farm.json` | this checkout only, gitignored |
| this repository | GitHub |

Put the first three in a password manager. Without the S3 keys there are no backups at all;
without the Vault keys the restored Vault volumes are unreadable, and every VTA's master seed
with them.

> **The k3s token needs no separate copy.** `random_password.k3s_token` is in the OpenTofu state,
> and the state is in the bucket. Pull the state before you apply and the rebuilt cluster keeps
> its original token. `make token` prints it.

---

## 2. Back up by hand

Take one before anything risky: an upgrade, a CRD change, a bulk delete.

### etcd

```bash
make snapshot                          # or: ./scripts/etcd-snapshot.sh save before-upgrade
make snapshots | tail -5               # the new entry must show an s3:// location
```

> **Nothing in `s3://`?** `ssh root@<server-1> 'journalctl -u k3s | grep -i s3 | tail -30'`.
> `NoSuchBucket` → wrong bucket or region, try `etcd_s3_bucket_lookup_type = "path"`.
> `SignatureDoesNotMatch` → wrong keys. `no such host` → bad endpoint (no `https://` prefix, no
> bucket name in it). Fixing tfvars is not enough on its own: `user_data` is under
> `ignore_changes`, so edit `/etc/rancher/k3s/config.yaml` on each node and restart k3s.

### Rancher

```bash
export KUBECONFIG=$PWD/stacks/01-infra/kubeconfig.yaml

kubectl apply -f - <<'EOF'
apiVersion: resources.cattle.io/v1
kind: Backup
metadata:
  name: manual-backup
spec:
  resourceSetName: rancher-resource-set-full
EOF

kubectl get backup manual-backup -o jsonpath='{.status.filename}{"\n"}'
```

No `schedule`, so it runs once. **Keep that filename** — a restore is addressed by it.

> The tarball carries Rancher's secrets and tokens and is **not encrypted**: the `Backup` sets no
> `encryptionConfigSecretName`. Whoever holds the S3 keys holds Rancher.

### Longhorn

```bash
export KUBECONFIG=$PWD/stacks/03-rke2-clusters/clusters/<cluster>/kubeconfig.yaml
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
```

`localhost:8080` → Volume → the volume → **Create Backup**, and wait for `Completed`.

```bash
kubectl -n longhorn-system get backups.longhorn.io
kubectl -n longhorn-system get backuptargets.longhorn.io    # AVAILABLE must be true
```

---

## 3. Restore by hand

### etcd — roll the management cluster back

All of it, to the moment of the snapshot. There is no per-namespace restore; for that, Longhorn
is the per-volume tool and the Rancher backup is the Rancher-scoped one.

The farm keeps running throughout. It has its own etcd, and its kubeconfig points straight at its
own API server rather than through Rancher.

```bash
make snapshots                                    # 1. find the filename

for ip in <server-1> <server-2> <server-3>; do    # 2. stop k3s everywhere
  ssh root@$ip 'systemctl stop k3s'
done
```

```bash
ssh root@<server-1>                               # 3. reset and restore on one server
k3s server --cluster-reset --etcd-s3 --cluster-reset-restore-path=<snapshot-file>
# from local disk instead:
#   --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<snapshot-file>
```

The endpoint, bucket, credentials and token are already in `/etc/rancher/k3s/config.yaml`, so
pass only the **filename**, never a path. Wait for `Managed etcd cluster membership has been
reset...`, press Ctrl-C, then `systemctl start k3s`.

```bash
for ip in <server-2> <server-3>; do               # 4. the other two rejoin as fresh members
  ssh root@$ip 'rm -rf /var/lib/rancher/k3s/server/db/ && systemctl start k3s'
done

export KUBECONFIG=$PWD/stacks/01-infra/kubeconfig.yaml   # 5. verify
kubectl get nodes
kubectl -n cattle-system get pods
```

Rancher lives in etcd, so it comes back with it. Give it five minutes before worrying; then
`kubectl -n cattle-system logs -l app=rancher --tail=100`.

> **Same procedure, no snapshot, when etcd has lost quorum** (two of three servers down): stop
> k3s everywhere, run `k3s server --cluster-reset` on the most up-to-date survivor, then wipe
> `db/` on the others and start them.

### Rancher — put Rancher's own state back

Rancher's controllers reconcile the objects the operator is about to write, so stand them down
first.

```bash
kubectl -n cattle-system scale deploy rancher --replicas=0

kubectl apply -f - <<EOF
apiVersion: resources.cattle.io/v1
kind: Restore
metadata:
  name: manual-restore
spec:
  backupFilename: <the filename from section 2>
  prune: true
EOF

kubectl get restore manual-restore -w       # wait for Completed
kubectl -n cattle-system scale deploy rancher --replicas=3
```

> **`prune` is on by default, and it deletes.** Anything in the resource set that the backup does
> not contain goes away — a downstream cluster registered after the backup included. Restore a
> recent backup, never last month's.

### Longhorn — put a volume back

**Longhorn never rolls a volume back in place.** A restore grows a *new* volume from the backup,
and you move the claim onto it. Nothing is finished until the workload runs on the new volume.

```bash
export KUBECONFIG=$PWD/stacks/03-rke2-clusters/clusters/<cluster>/kubeconfig.yaml

# 0. keep a way back: with reclaim policy Delete, deleting the PVC destroys the current volume
PV=$(kubectl -n <namespace> get pvc <pvc> -o jsonpath='{.spec.volumeName}')
kubectl patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

# 1. detach it
kubectl -n <namespace> scale deploy <workload> --replicas=0
```

**2.** UI → Backup → the volume → the backup → **Restore**, under a new name.

**3.** Free the claim, then give it to the restored volume:

```bash
kubectl -n <namespace> delete pvc <pvc>
kubectl delete pv "$PV"          # Retain, so the old volume survives, detached
```

**4.** UI → Volume → the restored volume → **Create PV/PVC**, with the original namespace and
PVC name.

```bash
kubectl -n <namespace> scale deploy <workload> --replicas=1     # 5. bring it back up
```

To undo, repeat steps 3–4 with the original volume, then delete the restored one.

---

## 4. If everything is gone

The Hetzner project is deleted. All you have is the bucket, the keys from section 1, and this
repository.

```bash
# 1. .env with the bucket and the S3 keys, then pull the site's real values
make tfvars-pull

# 2. state comes back from the bucket - with the original k3s token inside it
make init

# 3. three new servers, already holding that token in their config.yaml
make apply

# 4. restore the newest snapshot: section 3, unchanged. Rancher and the cluster
#    registrations come back with it.

# 5. rebuild the farm cluster's machines - it comes up EMPTY
make apply-rke2 CLUSTER=<cluster>

# 6. Longhorn returns pointed at the same backup target and lists every volume backup
make apply-vtafarm-platform CLUSTER=<cluster>

# 7. restore each volume and give it its PV/PVC (section 3)

# 8. unseal the transit Vault with the old Shamir keys; the farm Vault auto-unseals against it

# 9. the app - domain and did_hosting_* must be identical to before
make apply-vtafarm-app CLUSTER=<cluster>

# 10. recreate the tenant workloads, then point DNS at the new load balancer
```

> **Three gaps stand between this and a real recovery. Close them before you need them.**
>
> - **The farm cluster's etcd is backed up nowhere.** `spec.rkeConfig.etcd` is unset, so Rancher
>   keeps snapshots on the nodes only. Tenant namespaces are created by the API at runtime, not
>   by OpenTofu, so their Deployments, Services and PVCs exist in that etcd and nowhere else.
>   Longhorn returns the volumes' contents and nothing that says what to attach them to — which
>   is what makes step 10 manual.
> - **`04-vtafarm-platform` and `05-vtafarm-app` have never been pushed to `tfvars/`.** Run
>   `make tfvars-push`. One of those values, `did_hosting_private_key`, cannot be regenerated:
>   see [cluster-migration.md](cluster-migration.md) §2.
> - **`vault-init-*.json` exists only in your checkout.** Losing it makes step 8 impossible.

---

## 5. Drills

Back up → change something → restore → prove. Run each one once before you rely on the cluster.

Every drill is **two-sided**: something created *before* the backup must survive, and something
created *after* it must disappear. Prove only one half and you cannot tell a working restore from
one that wiped everything.

| Drill | Proves | Down for | Way back |
| --- | --- | --- | --- |
| A — Rancher | Rancher's own state | the Rancher UI, ~5 min | the backup you just took |
| B — etcd | the whole management cluster | the UI and k3s `kubectl`, ~10 min | a newer snapshot |
| C — Longhorn | one volume's data | one workload | the original volume, kept |

Run them in that order — the blast radius grows with each — and take an etcd snapshot before
starting, as the net under all three. Do not run `tofu apply` between a backup and the end of its
restore: state is in the bucket, not in the cluster, so rolling the cluster back would leave
OpenTofu believing in objects that no longer exist.

### Drill A — Rancher

1. Rancher UI → Users & Authentication → create user `drill-keep`. **Must survive.**
2. Take a Rancher backup (section 2) and note the filename.
3. Delete `drill-keep`, then create a second user `drill-extra`. **Must disappear.**
4. Restore that backup (section 3).
5. Prove it:

```bash
kubectl get users.management.cattle.io -o custom-columns=NAME:.metadata.name,USER:.username
```

`drill-keep` is back and `drill-extra` is gone. Clean up: delete `drill-keep`, then
`kubectl delete backup manual-backup`.

### Drill B — etcd

```bash
export KUBECONFIG=$PWD/stacks/01-infra/kubeconfig.yaml

# 1. the marker that must SURVIVE
kubectl create namespace restore-drill
kubectl -n restore-drill create configmap marker --from-literal=created="$(date -Is)"

# 2. the snapshot under test
./scripts/etcd-snapshot.sh save drill-$(date +%Y%m%d)
make snapshots | grep drill-
```

**3.** The change that must **disappear**: Rancher UI → Cluster Management → Import Existing →
Generic, named `drill-cluster`. **Never run the registration command it prints** — the cluster
stays Pending and no machine is created. Do not use `make apply-rke2` for this: it builds real
servers and records them in the state, which a restore does not roll back.

**4.** Restore the snapshot from step 2 (section 3).

**5.** Prove it:

```bash
kubectl -n restore-drill get configmap marker -o yaml   # back, original timestamp
kubectl get clusters.management.cattle.io               # drill-cluster gone
kubectl get nodes                                       # three Ready
kubectl delete namespace restore-drill
```

The farm cluster returns to Active in the Rancher UI a few minutes later, once its agent
reconnects. **Write down how long steps 4–5 took: that is your real Recovery Time Objective.**

### Drill C — Longhorn

Pick something small on a tenant you may disturb — one 200Mi PVC behind one Deployment.

1. Record what the app shows today. **Must survive.**
2. Back that volume up (section 2).
3. Add one item through the app — a DID, a record, anything visible. **Must disappear.**
4. Restore the backup from step 2 onto the workload (section 3).
5. Step 1's data is there; step 3's is not. Undo by swapping the original volume back.

> **A rehearsal, if a live tenant is too much.** Do the restore, but give the restored volume a
> PV/PVC under a different name in a scratch namespace and mount it on a `busybox` pod. Same
> evidence, nothing stopped. What it does not prove is that the app starts on restored data.

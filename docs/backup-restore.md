# Backup and Restore

> **A backup you have never restored is not a backup.** Section 6 is how you find out.

Three layers back themselves up independently, all into the same Hetzner bucket. Each covers
something the other two do not, and each gets a section below: how to back it up by hand, and
how to put it back.

| Layer | Holds | Restores |
| --- | --- | --- |
| **etcd** | the management cluster's whole datastore, Rancher included | the whole cluster, to a point in time |
| **Rancher** | Rancher's own state: users, roles, cluster registrations | Rancher, onto any cluster |
| **Longhorn** | the farm's data, one backup per volume | one volume at a time |

Schedules and retention are set in `terraform.tfvars` and summarised in
[operations.md](operations.md).

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

## 2. etcd — the whole management cluster

### Back up

Take one before anything risky: an upgrade, a CRD change, a bulk delete.

```bash
make snapshot                          # or: ./scripts/etcd-snapshot.sh save before-upgrade
make snapshots                         # everything that exists, local and S3
```

`make snapshot` prints the filename it ended up with — k3s appends the node name and a
timestamp — together with the `make restore` line that uses it. **Keep that filename.**

> **Nothing in `s3://`?** The cluster records every attempt, failures included — faster than
> `journalctl`, and it names the node:
>
> ```bash
> kubectl get etcdsnapshotfile -o json | jq -r '.items[] | select(.spec.s3)
>   | [.status.creationTime, .spec.nodeName, (.status.error.message // "OK")] | @tsv'
> ```
>
> `InvalidAccessKeyId` on the upload, or a bare `Access Denied` from the bucket test, both mean the
> node is holding a key that has been rotated away — one dead key reads two ways because HEAD has
> no response body to carry the real code. `NoSuchBucket` → wrong bucket or region, try
> `etcd_s3_bucket_lookup_type = "path"`. `no such host` → bad endpoint (no `https://` prefix, no
> bucket name in it).
>
> **Editing tfvars fixes nothing by itself.** `user_data` is under `ignore_changes` and cloud-init
> runs only on first boot, so `/etc/rancher/k3s/config.yaml` on a running node keeps whatever it
> was born with. Put the new pair in `/etc/rancher/k3s/config.yaml.d/10-etcd-s3-creds.yaml` and
> restart k3s one node at a time, waiting for Ready in between so etcd keeps quorum.

### Restore

All of it, to the moment of the snapshot. There is no per-namespace restore: for that, Longhorn
is the per-volume tool and the Rancher backup is the Rancher-scoped one.

The farm keeps running throughout. It has its own etcd, and its kubeconfig points straight at
its own API server rather than through Rancher.

```bash
make snapshots                                        # find the filename
make restore SNAPSHOT=<snapshot-file>                 # from S3
make restore SNAPSHOT=<snapshot-file> LOCAL=1         # from server-1's disk instead
```

It reads the node addresses out of the state, asks you to type the cluster name, and then does
the whole sequence: stop k3s everywhere, reset and restore on server-1, wipe `db/` on the others
so they rejoin as fresh members, and wait for the API server to answer. Add `--yes` to
`scripts/etcd-restore.sh` to skip the prompt when scripting it.

Rancher lives in etcd, so it comes back with it. Give it five minutes before worrying; then
`kubectl -n cattle-system logs -l app=rancher --tail=100`.

> **Doing it by hand instead**, one server at a time:
> `systemctl stop k3s` everywhere, then on server-1
> `k3s server --cluster-reset --etcd-s3 --cluster-reset-restore-path=<file>` — the endpoint,
> bucket, credentials and token are already in `/etc/rancher/k3s/config.yaml`, so pass only the
> **filename**, never a path. Wait for `Managed etcd cluster membership has been reset...`,
> Ctrl-C, `systemctl start k3s`. Then on the others,
> `rm -rf /var/lib/rancher/k3s/server/db/ && systemctl start k3s`.
>
> **Same procedure, no snapshot, when etcd has lost quorum** (two of three servers down): stop
> k3s everywhere, run `k3s server --cluster-reset` on the most up-to-date survivor, then wipe
> `db/` on the others and start them.

---

## 3. Rancher — users, roles, cluster registrations

```bash
export KUBECONFIG=$PWD/stacks/01-infra/kubeconfig.yaml
```

### Back up

```bash
kubectl apply -f - <<'EOF'
apiVersion: resources.cattle.io/v1
kind: Backup
metadata:
  name: manual-backup
spec:
  resourceSetName: rancher-resource-set-full
EOF

kubectl wait --for=condition=Ready backup/manual-backup --timeout=5m
kubectl get backup manual-backup -o jsonpath='{.status.filename}{"\n"}'
```

> The tarball carries Rancher's secrets and tokens and is **not encrypted**: the `Backup` sets no
> `encryptionConfigSecretName`. Whoever holds the S3 keys holds Rancher.

### Restore

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
  backupFilename: <the filename from above>
  prune: true
EOF

kubectl wait --for=condition=Ready restore/manual-restore --timeout=15m
kubectl -n cattle-system scale deploy rancher --replicas=3
```

> **`prune` is on by default, and it deletes.** Anything in the resource set that the backup does
> not contain goes away — a downstream cluster registered after the backup included. Restore a
> recent backup, never last month's.

---

## 4. Longhorn — the farm's volumes

```bash
export KUBECONFIG=$PWD/stacks/03-rke2-clusters/clusters/<cluster>/kubeconfig.yaml
kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
```

### Back up

`localhost:8080` → Volume → the volume → **Create Backup**, and wait for `Completed`.

```bash
kubectl -n longhorn-system get backups.longhorn.io
kubectl -n longhorn-system get backuptargets.longhorn.io    # AVAILABLE must be true
```

### Restore

**Longhorn never rolls a volume back in place.** A restore grows a *new* volume from the backup,
and you move the claim onto it. Nothing is finished until the workload runs on the new volume.

```bash
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

## 5. If everything is gone

The Hetzner project is deleted. All you have is the bucket, the keys from section 1, and this
repository.

```bash
# 1. .env with the bucket and the S3 keys, then pull the site's real values
make tfvars-pull

# 2. state comes back from the bucket - with the original k3s token inside it
make init

# 3. three new servers, already holding that token in their config.yaml
make apply

# 4. restore the newest snapshot (section 2). Rancher and the cluster
#    registrations come back with it.

# 5. rebuild the farm cluster's machines - it comes up EMPTY
make apply-rke2 CLUSTER=<cluster>

# 6. Longhorn returns pointed at the same backup target and lists every volume backup
make apply-vtafarm-platform CLUSTER=<cluster>

# 7. restore each volume and give it its PV/PVC (section 4)

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

## 6. Drills

Back up → change something → restore → prove. Run each one once before you rely on the cluster.

Every drill is **two-sided**: something that existed *before* the backup must survive, and
something created *after* it must disappear. Prove only one half and you cannot tell a working
restore from one that wiped everything.

Let the cluster as it stands be the surviving half wherever it can. Then the only thing a drill
creates is the marker the restore itself deletes, and finishing leaves nothing to tidy up — no
drill users, no drill namespaces, nothing for the next person to wonder about.

| Drill | Proves | Down for | Way back |
| --- | --- | --- | --- |
| A — etcd | the whole management cluster | the UI and k3s `kubectl`, ~10 min | a newer snapshot |
| B — Rancher | Rancher's own state | the Rancher UI, ~5 min | the backup you just took |
| C — Longhorn | one volume's data | one workload | the original volume, kept |

Run them in that order. A proves the net that B and C fall back on, and an etcd snapshot nobody
has ever restored is a poor thing to be holding when a later drill goes wrong. Take a fresh
snapshot before B and C as well. Do not run `tofu apply` between a backup and the end of its
restore: state is in the bucket, not in the cluster, so rolling the cluster back would leave
OpenTofu believing in objects that no longer exist.

### Drill A — etcd

This is the one drill that has to create its surviving half. A timestamp written before the
snapshot proves the restore landed on that *moment*; objects that were already there only prove
they were not deleted. Step 5 removes it again.

```bash
export KUBECONFIG=$PWD/stacks/01-infra/kubeconfig.yaml

# 1. the marker that must SURVIVE
kubectl create namespace restore-drill
kubectl -n restore-drill create configmap marker --from-literal=created="$(date -Is)"

# 2. the snapshot under test - note the filename it prints
./scripts/etcd-snapshot.sh save drill-$(date +%Y%m%d)
```

**3.** The change that must **disappear**: Rancher UI → Cluster Management → Import Existing →
Generic, named `drill-cluster`. **Never run the registration command it prints** — the cluster
stays Pending and no machine is created. Do not use `make apply-rke2` for this: it builds real
servers and records them in the state, which a restore does not roll back.

**4.** `make restore SNAPSHOT=<the filename step 2 printed>`

**5.** Prove it:

```bash
kubectl -n restore-drill get configmap marker -o yaml   # back, original timestamp
kubectl get clusters.management.cattle.io               # drill-cluster gone
kubectl get nodes                                       # three Ready
```

**6.** Take the marker back out, and the cluster is as you found it:

```bash
kubectl delete namespace restore-drill
```

The farm cluster returns to Active in the Rancher UI a few minutes later, once its agent
reconnects. **Write down how long steps 4–5 took: that is your real Recovery Time Objective.**

### Drill B — Rancher

The users already in the cluster are the half that must survive, so this drill creates nothing for
that side. The one thing it does add, the restore takes away again.

**1.** Record who is there now. Every one of them must come back:

```bash
export KUBECONFIG=$PWD/stacks/01-infra/kubeconfig.yaml
kubectl get users.management.cattle.io -o custom-columns=NAME:.metadata.name,USER:.username
```

**2.** Take a Rancher backup (section 3) and note the filename.

**3.** Rancher UI → Users & Authentication → create user `drill-extra`. **Must disappear.**

**4.** Restore that backup (section 3).

**5.** Prove it — step 1's list, unchanged, without `drill-extra`:

```bash
kubectl get users.management.cattle.io -o custom-columns=NAME:.metadata.name,USER:.username
```

**6.** The restore removed the only thing the drill created, so all that is left is the pair of
CRs. The tarball stays in the bucket; delete it there if you want it gone.

```bash
kubectl delete restore/manual-restore backup/manual-backup
```

> **Expect to be signed out.** `prune` deletes what the backup does not contain, and that includes
> the token behind any Rancher session opened after step 2 — the one you are using included.

### Drill C — Longhorn

Pick something small on a tenant you may disturb — one 200Mi PVC behind one Deployment.

1. Record what the app shows today. **Must survive.**
2. Back that volume up (section 4).
3. Add one item through the app — a DID, a record, anything visible. **Must disappear.**
4. Restore the backup from step 2 onto the workload (section 4).
5. Step 1's data is there; step 3's is not. Undo by swapping the original volume back.

> **A rehearsal, if a live tenant is too much.** Do the restore, but give the restored volume a
> PV/PVC under a different name in a scratch namespace and mount it on a `busybox` pod. Same
> evidence, nothing stopped. What it does not prove is that the app starts on restored data.

# Teardown

You can destroy each layer on its own. Work from the top down: first the applications, then
the platform, then the downstream cluster, and last the management cluster.

## The applications only

The PersistentVolumeClaim of the database has the annotation `helm.sh/resource-policy: keep`,
and its storage class keeps the volume. The data therefore survives, and a later apply
connects to the same volume again. Its password survives too: the secret holding it is
`prevent_destroy`, and the destroy excludes it, because the volume is unreadable without it.

```bash
make destroy-vtafarm-app CLUSTER=rke2-vtafarm-production
```

### Including the database

That command leaves three objects behind on purpose, and OpenTofu manages none of them: the
PVC, the PV that `longhorn-retain` keeps, and the Longhorn volume underneath it. Deleting the
PVC alone frees no disk — under `Retain` the volume outlives its claim. Remove all of it by
hand when the data really is meant to go:

```bash
export KUBECONFIG=$PWD/stacks/03-rke2-clusters/clusters/<cluster>/kubeconfig.yaml
APP=stacks/05-vtafarm-app/clusters/<cluster>
PV="$(kubectl get pvc vtafarm-api-postgresql -n default -o jsonpath='{.spec.volumeName}')"

tofu -chdir="$APP" state rm module.app.kubernetes_secret_v1.postgres
kubectl delete secret vtafarm-api-postgresql -n default
kubectl delete pvc    vtafarm-api-postgresql -n default
kubectl delete pv     "$PV"
kubectl delete volumes.longhorn.io "$PV" -n longhorn-system
```

Read the PV name before anything else — it comes from the PVC, which is the first thing to go.
`state rm` leads because `prevent_destroy` has no command-line override; it only makes OpenTofu
forget the secret and does not touch the cluster. `-n default` follows `namespace` in the app's
tfvars. A later apply recreates the secret from the password still held in state and initialises
an empty database on a new volume.

## One cluster's platform layer

cert-manager, Longhorn and both Vaults, keeping the RKE2 cluster they run on:

```bash
make destroy-vtafarm-platform CLUSTER=rke2-vtafarm-production
```

> This deletes the Vault PVCs, and with them every seed that the farm Vault held. The only way
> to get them back is a Raft snapshot together with the recovery keys. See
> [vault.md](vault.md).

## One downstream RKE2 cluster

This does not touch stack 01, stack 02, or the other RKE2 clusters:

```bash
make destroy-rke2 CLUSTER=rke2-vtafarm-production
```

## Rancher only

This removes cert-manager, Rancher, the backup operator and the upgrade controller. It keeps
the k3s infrastructure and the RKE2 infrastructure, which are managed separately:

```bash
make destroy-rancher
```

## Everything

```bash
make destroy
```

The command reads `stacks/03-rke2-clusters/clusters/*` and destroys every cluster directory
first, while Rancher is still running and can accept the deletions. It destroys stack 01 only
after every RKE2 destroy has succeeded. If a step fails, the command stops. It does not delete
the layers that the failed step depends on.

The command skips stacks 02, 04 and 05 on purpose. Everything they own runs inside a cluster
that is about to be destroyed, so a separate `helm uninstall` run would only cost time. Those
resources disappear without OpenTofu knowing about it, so the command deletes their state files
after the cluster is gone. An old state file would make the next apply refresh against a
cluster that no longer exists.

> The order matters. Keep every generated RKE2 directory and its OpenTofu state until you have
> destroyed that cluster. Without the state file, `make destroy` cannot find those Rancher and
> Hetzner resources and cannot remove them safely.

When you are finished, open the Hetzner Console and look for Volumes that remain. OpenTofu
does not manage the PVs that the CSI driver creates. Volumes with `reclaimPolicy: Delete`
disappear by themselves, but volumes with `Retain` stay and you keep paying for them.

## Resetting the checkout

`make clean` removes what a fresh clone would not have: every `.terraform` directory, the
`terraform.tfvars` of stacks 01 and 02, and the `clusters/` directory of stacks 03 to 05. It
asks first, and it touches nothing remote — the state bucket keeps both the state files and
the tfvars, and any running cluster keeps running.

Destroy before you clean. `make destroy` finds the RKE2 clusters by reading
`stacks/03-rke2-clusters/clusters/*`; with those roots gone it destroys stack 01 and leaves
the downstream Rancher and Hetzner resources behind.

Coming back afterwards is the same path a second operator takes:

```bash
make init
make tfvars-pull
make new-rke2-cluster CLUSTER=rke2-vtafarm-production
make new-vtafarm-platform CLUSTER=rke2-vtafarm-production
make new-vtafarm-app CLUSTER=rke2-vtafarm-production
make tfvars-pull    # the cluster roots now exist, so their tfvars land too
make init-rke2 CLUSTER=rke2-vtafarm-production
```

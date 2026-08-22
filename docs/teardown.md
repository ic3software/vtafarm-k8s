# Teardown

You can destroy each layer on its own. Work from the top down: first the applications, then
the platform, then the downstream cluster, and last the management cluster.

## The applications only

The PersistentVolumeClaim of the database has the annotation `helm.sh/resource-policy: keep`,
and its storage class keeps the volume. The data therefore survives, and a later apply
connects to the same volume again:

```bash
make destroy-vtafarm-app CLUSTER=rke2-vtafarm-production
```

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

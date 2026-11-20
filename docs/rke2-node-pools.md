# RKE2 node pools

Named pools let different Hetzner server shapes coexist in one Rancher-provisioned RKE2
cluster. Every pool has an independent count and server type.
Server pools carry the `etcd` and `controlplane` roles; worker pools carry only `worker`.

The pool name is included in new node names and in the Hetzner `node_pool` label:

```text
rke2-vtafarm-staging-control-plane-green-1
rke2-vtafarm-staging-worker-batch-1
```

`legacy` is reserved for adopting an existing cluster. It keeps the original names, private
addresses and OpenTofu resource keys (`server-1`, `worker-1`, and so on), so introducing the
pool model does not replace or reconnect any VM.

## Node numbering and private addresses

Every pool has its own one-based node sequence, such as `control-plane-green-1` through
`control-plane-green-3`. Hetzner assigns private addresses for named pools and the bootstrap discovers
them before registering with Rancher. The module internally preserves the legacy pool's old
addresses; users do not allocate address slots in pool config.

## Move three CX33 servers to CX43

Take an etcd snapshot and confirm Longhorn backups before changing membership. The migration
uses two separate `make apply-rke2` runs.

### 1. Add the CX43 pool

Start with the legacy pool representing the existing nodes, then add `green`. Only the three
`green` nodes are new.

```hcl
server_pool_migration = true

server_pools = {
  legacy = {
    count         = 3
    server_type   = "cx33"
    auto_location = false
  }

  green = {
    count         = 3
    server_type   = "cx43"
    auto_location = true
  }
}
```

`auto_location = false` pins a pool to the cluster `location`. With `true`, the location is
omitted and Hetzner chooses among the server type's locations in the same network zone. The
Hetzner API does not support a preferred location followed by ordered fallbacks, so automatic
placement may choose any of those locations rather than trying the configured location first.

The migration flag is an explicit acknowledgement that etcd temporarily has an even six
members. Six members require a quorum of four and tolerate only two failures, the same as five;
the even topology is for migration, not steady state.

```bash
make plan-rke2  CLUSTER=rke2-vtafarm-staging
make apply-rke2 CLUSTER=rke2-vtafarm-staging
kubectl --kubeconfig=stacks/03-rke2-clusters/clusters/rke2-vtafarm-staging/kubeconfig.yaml get nodes -w
```

The plan must create three `control-plane-green-*` resources and must not delete or replace a
`server-*` resource. Wait until all six nodes are Ready and Rancher reports the cluster Active.

### 2. Retire the CX33 pool

Remove `legacy` and return to an odd steady-state membership:

```hcl
server_pool_migration = false

server_pools = {
  green = {
    count         = 3
    server_type   = "cx43"
    auto_location = true
  }
}
```

The plan must contain only deletion of the three legacy-pool servers and their load-balancer
targets. Run the wrapper, not a direct `tofu apply`:

```bash
make apply-rke2 CLUSTER=rke2-vtafarm-staging
```

Before OpenTofu may delete a VM, the wrapper:

1. rejects combined node creation and deletion;
2. verifies every surviving node and etcd endpoint is healthy;
3. cordons every retiring node so data cannot move to the next node being removed;
4. disables Longhorn scheduling and waits for replicas and backing images to evacuate;
5. drains the node without bypassing PDBs or deleting `emptyDir` data;
6. verifies that no engine, volume or CSI attachment still uses the node;
7. asks Rancher to retire its Machine and remove the etcd member;
8. rechecks etcd after each member; and
9. applies the saved plan only after all retiring Kubernetes nodes are gone.

Any failed safety check stops the run while the Hetzner VMs are still present. Fix the reported
condition and run the same command again; partial retirement is resumable.

## Development clusters

A dev cluster normally has one control-plane node and no load balancer. For a shape migration,
set `server_pool_migration = true` and define exactly two one-node pools: `legacy` and one
replacement pool. The legacy node keeps the stable public API Primary IP while the replacement
joins over the private network. After the replacement is Ready, remove `legacy` and set the flag
back to `false`; the apply wrapper permits the dev cluster to retire down to its single healthy
replacement etcd member.

Dev pools remain pinned to the configured `location`, even when `auto_location = true`, because
the stable Primary IP is location-bound. Normal HA clusters can use automatic placement within
their private-network zone.

## Worker pools

Workers use the same model but do not need the temporary-etcd flag:

```hcl
worker_pools = {
  legacy = {
    count         = 3
    server_type   = "cx33"
    auto_location = false
  }

  batch = {
    count         = 3
    server_type   = "cpx32"
    auto_location = true
  }
}
```

Add the new worker pool in one apply and remove the old pool in a later apply. Longhorn uses the
same evacuation boundary for worker and server pools.

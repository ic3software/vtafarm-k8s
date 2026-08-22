# Testing the cluster

## Quick health check

```bash
make status
```

Shows nodes, etcd members, any non-Running pods, the Rancher deployment and certificates.

---

## Detailed verification

```bash
kubectl config use-context k3s-rancher

# 1. Three Ready nodes, all of them actual etcd members
kubectl get nodes -L node-role.kubernetes.io/etcd

# 2. etcd is healthy (run against any server)
ssh root@<server-1-public-ip> 'k3s kubectl get --raw "/healthz?verbose"' | grep etcd

# 3. The Hetzner CCM is up and nodes carry a providerID
kubectl -n kube-system get pods -l app.kubernetes.io/name=hcloud-cloud-controller-manager
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.providerID}{"\n"}{end}'
# expect hcloud://<server-id>

# 4. Traefik runs as a DaemonSet, one pod per node
kubectl -n kube-system get ds traefik -o wide

# 5. Every load balancer service reports healthy targets
#    (Hetzner Console → Load Balancers → Targets)

# 6. Rancher has three replicas spread across nodes
kubectl -n cattle-system get pods -o wide -l app=rancher
```

---

## HA failover test — run this once, before you rely on the cluster

This test is the only way to find out whether the cluster is really highly available.

```bash
# choose a node that you are NOT connected to, and power it off
hcloud server poweroff k3s-rancher-server-3     # or use the Console
```

In another terminal:

```bash
watch kubectl get nodes
```

Expected behaviour:

| When | What happens |
| --- | --- |
| immediately | `kubectl` keeps working. The load balancer sends traffic to the other two servers |
| ~40s | the node goes `NotReady` |
| ~5 min | Kubernetes evicts its pods and schedules them on the other nodes |
| throughout | `https://rancher.yourdomain.com` stays available |

```bash
hcloud server poweron k3s-rancher-server-3
kubectl get nodes          # back to Ready within a minute or two
```

> **What happens if you stop a second node?** etcd loses its quorum, because 1 of 3 nodes is
> less than the required `(3/2)+1 = 2`. **The API server then stops answering.** This is
> correct etcd behaviour, not a bug. To survive two failures at the same time, you need five
> servers.

Restoring from a backup is a separate drill. See [backup-restore.md](backup-restore.md).

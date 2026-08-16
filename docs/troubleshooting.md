# Troubleshooting

## Where to look first

Almost every bootstrap problem is visible in one of these:

```bash
# what cloud-init and the bootstrap script did
ssh root@<node-ip> 'tail -100 /var/log/cloud-init-output.log'

# what k3s itself is saying
ssh root@<node-ip> 'journalctl -u k3s -n 200 --no-pager'

# did the bootstrap script finish at all?
ssh root@<node-ip> 'ls -l /var/lib/rancher/.k3s-bootstrap-done'
```

The bootstrap script prefixes every line with `[k3s-bootstrap]`, so:

```bash
ssh root@<node-ip> 'grep k3s-bootstrap /var/log/cloud-init-output.log'
```

---

## Nodes stay `NotReady` with an `uninitialized` taint

```bash
kubectl get nodes
kubectl describe node <name> | grep -A5 Taints
# node.cloudprovider.kubernetes.io/uninitialized:NoSchedule
```

**Cause.** k3s runs with `--kubelet-arg=cloud-provider=external`, so every node is tainted
until the Hetzner cloud controller manager (CCM) clears it. If the CCM never installs, nothing
can be scheduled and the cluster looks dead.

**Diagnose.**

```bash
# is the HelmChart resource there and did its job run?
kubectl -n kube-system get helmchart hcloud-cloud-controller-manager
kubectl -n kube-system get jobs | grep hcloud
kubectl -n kube-system logs job/helm-install-hcloud-cloud-controller-manager

# is the CCM pod running?
kubectl -n kube-system get pods -l app.kubernetes.io/name=hcloud-cloud-controller-manager
kubectl -n kube-system logs -l app.kubernetes.io/name=hcloud-cloud-controller-manager
```

**Common causes.**

| Symptom in the logs | Fix |
| --- | --- |
| `hcloud/newCloud: unable to authenticate` | The Hetzner token in the `hcloud` secret is wrong or expired. Check with `kubectl -n kube-system get secret hcloud -o jsonpath='{.data.token}' \| base64 -d` |
| helm job cannot reach `charts.hetzner.cloud` | Outbound DNS/HTTPS is blocked. The job runs with `hostNetwork`, so test from the node: `ssh root@<node> 'curl -sI https://charts.hetzner.cloud/index.yaml'` |
| the HelmChart resource does not exist at all | The manifest never landed. Check `ssh root@<node> 'ls -l /var/lib/rancher/k3s/server/manifests/'` |

**Manual unblock** (gets you moving; fix the root cause afterwards):

```bash
kubectl taint nodes --all node.cloudprovider.kubernetes.io/uninitialized-
```

---

## The second and third servers never join

Symptoms: `kubectl get nodes` shows only one node, and the missing ones have k3s failing to
start.

```bash
ssh root@<server-2> 'grep k3s-bootstrap /var/log/cloud-init-output.log | tail -20'
ssh root@<server-2> 'journalctl -u k3s -n 100 --no-pager'
```

| What you see | Meaning | Fix |
| --- | --- | --- |
| `waiting for the private network interface to appear ...` repeated | Hetzner has not exposed the private NIC to the guest | Check the server's private-network attachment in the Hetzner Console; inspect `ip -o link show` on the node |
| `waiting for private IP 10.0.1.102 on enp7s0 ...` repeated | The NIC exists but DHCP did not assign the IP requested by OpenTofu | Inspect `/etc/netplan/60-k3s-private-network.yaml`, then run `netplan generate && netplan apply`; compare `ip -o -4 addr` with `tofu output servers` |
| `waiting for peer 10.0.1.10 ...` never succeeds | The API load balancer is not forwarding | Hetzner Console → Load Balancers → your cluster's LB → Targets. If server-1 is unhealthy, its k3s is not listening on 6443 |
| `failed to validate server token` | Token mismatch — the node has different `token:` than the cluster | Compare `/etc/rancher/k3s/config.yaml` across nodes |
| `etcdserver: too many learner members in cluster` | Two nodes tried to join simultaneously | Restart k3s on the failing node: `systemctl restart k3s`. It retries and succeeds |

To retry a node from scratch:

```bash
tofu -chdir=stacks/01-infra apply -replace='hcloud_server.server[1]'
```

---

## Let's Encrypt certificate is never issued

```bash
kubectl -n cattle-system get certificate
kubectl -n cattle-system describe certificate tls-rancher-ingress
kubectl -n cattle-system get certificaterequest,order,challenge
kubectl -n cert-manager logs -l app=cert-manager --tail=100
```

Work through the chain: `Certificate` → `CertificateRequest` → `Order` → `Challenge`. The
error is usually on the `Challenge`.

| Challenge error | Cause | Fix |
| --- | --- | --- |
| `Waiting for HTTP-01 challenge propagation` forever | DNS does not resolve to the ingress LB | `dig +short rancher.yourdomain.com` must return `load_balancer_ipv4` |
| connection timeout to `http://…/.well-known/acme-challenge/…` | Port 80 does not reach Traefik | See the load balancer section below |
| `too many failed authorizations` | You hit the production rate limit | Fix DNS or port 80, then retry after the rate-limit window |
| `urn:ietf:params:acme:error:unauthorized` | The challenge is being answered by something else on that hostname | Make sure no other ingress claims the same host |

Test the challenge path by hand:

```bash
curl -v http://rancher.yourdomain.com/.well-known/acme-challenge/test
# expect a 404 from Traefik — that proves the path is reachable
```

Force a reissue:

```bash
kubectl -n cattle-system delete secret tls-rancher-ingress
kubectl -n cattle-system delete certificate tls-rancher-ingress
make apply-platform
```

---

## Load balancer targets are unhealthy

Hetzner Console → Load Balancers → Targets shows red.

Targets belong to the load balancer, health checks belong to each service — so every service
checks every target. Every node runs both the API server and Traefik, so all three services
should be green. A red target means that node genuinely is not listening.

**The Kubernetes API service** (health check TCP 6443):

```bash
# is k3s listening on the private IP?
ssh root@<server-1> 'ss -tlnp | grep 6443'
# reachable from another node?
ssh root@<server-2> 'curl -sk https://10.0.1.101:6443/cacerts | head -3'
```

**The ingress services** (health check TCP 80/443):

```bash
# Traefik should be scheduled on every node
kubectl -n kube-system get ds traefik -o wide
kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik -o wide

# is it actually bound to the host port?
ssh root@<node> 'ss -tlnp | grep -E ":80|:443"'
```

If Traefik is a `Deployment` rather than a `DaemonSet`, the `HelmChartConfig` did not apply:

```bash
kubectl -n kube-system get helmchartconfig traefik -o yaml
ssh root@<server-1> 'cat /var/lib/rancher/k3s/server/manifests/30-traefik-config.yaml'
```

---

## Ingress returns garbage, or clients see the wrong source IP

This is the PROXY protocol setting. The load balancer sends a PROXY header on :80/:443, and Traefik
must be told to trust and parse it.

```bash
kubectl -n kube-system get helmchartconfig traefik -o jsonpath='{.spec.valuesContent}'
# ports.web.proxyProtocol.trustedIPs should contain your network_cidr
```

If HTTP is completely broken right after enabling it, the two sides disagree. Turn it off to
confirm:

```hcl
# stacks/01-infra/terraform.tfvars
enable_proxy_protocol = false
```

```bash
make apply
```

(That change only touches the load balancer services, not the servers, so it applies cleanly.
The Traefik side needs the manifest updated too — edit
`/var/lib/rancher/k3s/server/manifests/30-traefik-config.yaml` on the servers, or roll them.)

---

## Rancher pods in `CrashLoopBackOff`

```bash
kubectl -n cattle-system get pods
kubectl -n cattle-system logs -l app=rancher --tail=100 --previous
```

| Log message | Cause |
| --- | --- |
| `Rancher must be installed on a supported Kubernetes version` | k3s is outside Rancher's support matrix. Check the README version table |
| OOMKilled (`kubectl describe pod` shows it) | Out of memory. `cx23` gives 4 GB per node, which fits k3s + etcd + one Rancher replica with little to spare, and a Rancher upgrade briefly doubles the replicas. Confirm with `kubectl top nodes`, then raise `server_type` to `cx33` and roll the nodes one at a time |
| `failed to get ingress` / waiting on TLS | The certificate is not ready yet; fix the cert-manager chain first |
| `replicas` exceed schedulable nodes | `rancher_replicas` must be ≤ the number of nodes that can accept the pods |

---

## `tofu plan` wants to replace server nodes

```bash
make plan | grep -B5 "must be replaced"
```

Servers carry `lifecycle { ignore_changes = [user_data, ssh_keys, image] }`, so this should be
rare. If it still happens, something else changed — `server_type`, `location`, or
`placement_group_id`.

**Never let a single apply replace all three.** Roll them individually and wait for each to
return to `Ready`:

```bash
tofu apply -replace='hcloud_server.server[2]'
kubectl get nodes -w
# then [1], then [0]
```

---

## `make apply-platform` fails with "cannot load kubeconfig"

Stack 02 reads `../../kubeconfig`, which stack 01 writes.

```bash
ls -l kubeconfig
make kubeconfig        # re-fetch it
kubectl get nodes      # confirm it works
```

---

## kubectl hangs or times out

```bash
# can you reach the API load balancer at all?
nc -vz <api_load_balancer_ipv4> 6443

# how many servers are up?
kubectl get nodes
```

If two of three servers are down, etcd has lost quorum and the API server intentionally stops
serving. See [backup-restore.md, Scenario B](backup-restore.md#6-scenario-b--etcd-lost-quorum-two-or-more-servers-down).

---

## Everything looks fine but a pod cannot reach another pod

Almost always flannel binding to the wrong interface.

```bash
# every node should show the private NIC, e.g. enp7s0
for ip in <node-ips>; do
  ssh root@$ip 'cat /etc/rancher/k3s/config.yaml.d/10-node.yaml'
done

# and the flannel public-ip annotation should be a 10.x address
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip}{"\n"}{end}'
```

If any node shows a public IP there, Virtual Extensible LAN (VXLAN) traffic is trying to cross
the internet and the firewall blocks it. Fix `flannel-iface` on that node and
`systemctl restart k3s`.

---

## Starting over from scratch

```bash
make destroy
# check the Hetzner Console for leftover Volumes (Retain-policy PVs are not OpenTofu-managed)
make apply
```

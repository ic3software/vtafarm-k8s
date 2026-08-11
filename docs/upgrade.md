# Upgrade Runbook

Three independent components. Recommended order: **k3s → Rancher → operating system**.

**Always snapshot first:**

```bash
make snapshot
```

---

## 0. Version compatibility — check this every single time

The Rancher chart declares a `kubeVersion` range and **helm refuses to install outside it** —
this fails hard, it does not degrade. Verify before every k3s bump:

```bash
curl -s https://releases.rancher.com/server-charts/stable/index.yaml \
  | yq '.entries.rancher[0] | {"version": .version, "kubeVersion": .kubeVersion}'
```

| Rancher chart | Enforced `kubeVersion` | Usable k3s minors |
| --- | --- | --- |
| 2.14.x | `< 1.36.0-0` | v1.33 / v1.34 / v1.35 |
| 2.15.x | `< 1.37.0-0` | v1.34 / v1.35 / v1.36 |

Current support matrix: <https://www.suse.com/suse-rancher/support-matrix/all-supported-versions/>

Current k3s channel heads:

```bash
curl -s https://update.k3s.io/v1-release/channels \
  | jq -r '.data[] | "\(.id)\t\(.latest)"'
```

> ⚠️ **Do not follow the k3s `stable` channel.** At the time of writing it points at v1.36,
> which Rancher 2.14.x rejects. This is exactly why the repo pins an explicit version instead of
> a channel — a channel would upgrade you out of the supported range unattended.

---

## 1. Upgrading k3s

### How it works

`system-upgrade-controller` — the
[approach documented by k3s](https://docs.k3s.io/upgrades/automated) — is installed in the
`system-upgrade` namespace with a `server-plan`:

- `concurrency: 1` — **one node at a time**, so etcd never loses quorum
- `cordon: true` — the node is marked unschedulable before the swap
- the version is **pinned**, so nothing happens until you change it

### Procedure

```hcl
# stacks/02-platform/terraform.tfvars
k3s_target_version = "v1.35.8+k3s1"
```

```bash
make snapshot
make apply-platform
```

### Watch it

```bash
# one job per node
kubectl -n system-upgrade get jobs -w

# nodes go SchedulingDisabled → Ready, in sequence
kubectl get nodes -w

# logs when something looks wrong
kubectl -n system-upgrade logs -l upgrade.cattle.io/plan=server-plan --tail=100
```

Budget 2–4 minutes per node, roughly 10 minutes for three.

### Verify

```bash
kubectl get nodes -o wide         # VERSION shows the new release on all three
make status
```

### When it gets stuck

```bash
# inspect the plan
kubectl -n system-upgrade get plan server-plan -o yaml

# a node left cordoned
kubectl uncordon <node-name>

# abandon the upgrade and handle it manually
kubectl -n system-upgrade delete plan server-plan
```

### Upgrading one node by hand

```bash
ssh root@<node-ip>
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.35.8+k3s1" sh -s -
systemctl restart k3s
```

Configuration lives in `/etc/rancher/k3s/config.yaml` and is not touched by a reinstall.

---

## 2. Upgrading Rancher

### Rules

- **No skipping minors.** 2.12 → 2.14 is not supported; go 2.12 → 2.13 → 2.14.
- Take an etcd snapshot first — that snapshot *is* the rollback path.
- Confirm the target Rancher version accepts your current Kubernetes version, and bump
  `rancher_backup_chart_version` with it — that chart is pinned to a Rancher minor via
  `catalog.cattle.io/rancher-version`.

### Procedure

```hcl
# stacks/02-platform/terraform.tfvars
rancher_chart_version = "2.14.4"
```

```bash
make snapshot
make apply-platform
```

### Watch it

```bash
kubectl -n cattle-system rollout status deploy/rancher
kubectl -n cattle-system get pods -w
```

All three replicas roll; brief 502s from the UI during the rollout are normal.

### Verify

```bash
kubectl -n cattle-system get deploy rancher \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

Then log into the UI and confirm every downstream cluster is still Active.

### Rollback

Rancher has no supported downgrade path. The only reliable rollback is restoring the etcd
snapshot taken before the upgrade — see
[backup-restore.md, Scenario C](backup-restore.md#7-scenario-c--full-restore-from-a-snapshot).

---

## 3. Upgrading cert-manager

```hcl
# stacks/02-platform/terraform.tfvars
cert_manager_version = "v1.22.0"
```

```bash
make apply-platform
```

CRDs are managed by the chart (`crds.enabled=true`) and upgrade with it. Afterwards:

```bash
kubectl get certificate -A
kubectl -n cattle-system describe certificate tls-rancher-ingress | tail -20
```

---

## 4. Operating system updates

`unattended-upgrades` installs security patches automatically but deliberately never reboots —
auto-rebooting control-plane nodes is a bad idea.

### Which nodes need a reboot

```bash
for ip in $(terraform -chdir=stacks/01-infra output -json server_nodes | jq -r '.[].public_ip'); do
  echo -n "$ip: "
  ssh -o StrictHostKeyChecking=accept-new root@$ip \
    'test -f /var/run/reboot-required && echo "reboot needed" || echo OK'
done
```

### Reboot one node at a time

```bash
NODE=k3s-rancher-server-2
IP=<public ip of that node>

# 1. move workloads off
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --timeout=300s

# 2. patch and reboot
ssh root@$IP 'apt-get update && apt-get -y upgrade && reboot'

# 3. wait for it to come back (about a minute)
until kubectl get node $NODE \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
  echo "waiting for $NODE ..."; sleep 10
done

# 4. allow scheduling again
kubectl uncordon $NODE
```

**Leave at least five minutes between nodes** and confirm etcd has fully recovered before
touching the next one:

```bash
kubectl get nodes
ssh root@$IP 'k3s kubectl get --raw "/healthz?verbose"' | grep etcd
```

### Automating it

[kured](https://kured.dev/) (Kubernetes Reboot Daemon) watches for
`/var/run/reboot-required` and performs exactly this drain/reboot/uncordon cycle, one node at a
time.

---

## 5. Upgrading Terraform providers

```bash
terraform -chdir=stacks/01-infra init -upgrade
terraform -chdir=stacks/02-platform init -upgrade
```

`.terraform.lock.hcl` changes — **commit it**.

Always plan before applying, and look specifically for replacements:

```bash
make plan | grep -E "must be replaced|forces replacement"
```

If a provider release turns some attribute into a force-replacement, it will rebuild your
control plane. Stop and read the provider CHANGELOG before continuing.

---

## Checklist

```text
[ ] target version is inside Rancher's support matrix
[ ] make snapshot, and make snapshots shows it in S3
[ ] make plan / make plan-platform show no unexpected replacements
[ ] upgrade k3s; all three nodes report the new version
[ ] upgrade Rancher; rollout completes
[ ] make status is clean
[ ] Rancher UI reachable, downstream clusters Active
[ ] OS updates, one node at a time, five minutes apart
```

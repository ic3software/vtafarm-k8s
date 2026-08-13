# k3s HA + Rancher + downstream RKE2 on Hetzner Cloud

Terraform for a **3-node high-availability (HA) k3s cluster with embedded etcd** on Hetzner
Cloud, running **Rancher**, with **backups** and **upgrades** wired up from day one.

The HA topology follows the [official k3s embedded-etcd HA guide](https://docs.k3s.io/datastore/ha-embedded):
an odd number of server nodes, the first started with `--cluster-init`, the rest joining through a
**fixed registration address** (a Hetzner Load Balancer in this setup).

---

## Contents

- [Architecture](#architecture)
- [Terraform in three minutes](#terraform-in-three-minutes)
- [Prerequisites](#prerequisites)
- [Deploy](#deploy)
- [Testing](#testing)
- [Backups](#backups)
- [Upgrades](#upgrades)
- [Day-2 operations](#day-2-operations)
- [Troubleshooting](#troubleshooting)
- [Cost](#cost)
- [Teardown](#teardown)

---

## Architecture

```text
                          internet
                              │
                ┌─────────────▼──────────────┐
                │  Hetzner Load Balancer     │
                │    :6443  Kubernetes API   │  → servers
                │    :80    HTTP  ─┐         │  → all nodes
                │    :443   HTTPS ─┘ Traefik │
                └─────────────┬──────────────┘
                          10.0.1.10
  ┌───────────────────────────┴────────────────────────────┐
  │           Hetzner private network 10.0.1.0/24          │
  │                                                        │
  │   server-1          server-2          server-3         │
  │   10.0.1.101        10.0.1.102        10.0.1.103       │
  │   ┌──────────┐      ┌──────────┐      ┌──────────┐     │
  │   │ k3s      │      │ k3s      │      │ k3s      │     │
  │   │ + etcd   │◄────►│ + etcd   │◄────►│ + etcd   │     │
  │   │ Traefik  │      │ Traefik  │      │ Traefik  │     │
  │   │ Rancher  │      │ Rancher  │      │ Rancher  │     │
  │   └──────────┘      └──────────┘      └──────────┘     │
  │         placement group = spread (separate hosts)      │
  └────────────────────────────┬───────────────────────────┘
                               │
                               ▼  etcd snapshot every 6h
                  Hetzner Object Storage (S3)
```

### Design decisions worth knowing about

| Decision | Why |
| --- | --- |
| **3 servers with embedded etcd** | etcd needs a quorum of `(n/2)+1`, so the server count must be odd and at least 3. Three nodes tolerate one failure. |
| **k3s pinned to v1.35.7, Rancher to 2.14.3** | The Rancher chart declares a `kubeVersion` constraint that helm enforces: `2.14.x -> < 1.36.0-0`. The k3s `stable` channel is on v1.36, so following it would make `helm install rancher` fail outright. v1.35.7 is the newest k3s that 2.14.3 accepts. |
| **API behind a load balancer (fixed registration address)** | Nodes join via `https://10.0.1.10:6443`. Any server can be replaced without the others noticing, and your kubeconfig points at the same stable address. |
| **One load balancer, three services** | A Hetzner load balancer serves up to 5 services and 10,000 concurrent connections. A management cluster whose ingress traffic is a couple of admins has nothing to gain from a second one, so :6443, :80 and :443 share it. Targets belong to the load balancer while health checks belong to each service, and every node runs both the API server and Traefik, so all three services report green. |
| **All k3s traffic on the private network** | Hetzner Cloud Firewalls only filter the **public** interface — private network traffic is never inspected. So etcd (2379-2380), the API (6443), flannel's Virtual Extensible LAN tunnel (VXLAN, 8472) and the kubelet (10250) all bind to private IPs, and the public interface only exposes SSH. |
| **Placement group `spread`** | Without it, three "HA" servers can land on the same physical host and one hardware failure costs you etcd quorum. |
| **Hetzner cloud controller manager (CCM) manages nodes, Terraform manages load balancers** | The CCM sets `providerID`, topology labels and node lifecycle. Its load-balancer controller is switched off (`HCLOUD_LOAD_BALANCERS_ENABLED=false`) — otherwise it creates load balancers Terraform doesn't know about, which survive `terraform destroy` and keep billing you. |
| **Traefik as a DaemonSet with hostPorts** | Installing an external CCM requires `--disable-cloud-controller`, which also removes k3s' built-in servicelb (klipper). Traefik binds directly to `:80`/`:443` on the host instead, so the load balancer has something to reach. |
| **IPv4 only on the nodes** | One address family is one set of firewall rules to reason about. Hetzner still gives the load balancer an IPv6 address and offers no switch for that, but it reaches the nodes over private IPv4 regardless. |
| **`cx23` on x86, not the ARM64 `cax` line** | `cx23` is 2 vCPU / 4 GB / 40 GB NVMe on shared AMD EPYC. The memory budget is deliberately tight — k3s with etcd takes ~1 GB, a Rancher replica 1–1.5 GB, the bundled add-ons ~0.5 GB — so watch for OOMKills during Rancher upgrades and step up to `cx33` if they appear. The `cax` (ARM64) line is cheaper still, but [Rancher documents ARM64 as experimental and not recommended for production](https://ranchermanager.docs.rancher.com/how-to-guides/advanced-user-guides/enable-experimental-features/rancher-on-arm64). |

### Repository layout

```text
.
├── Makefile                    # every common task is a make target
├── stacks/
│   ├── 01-infra/               # Hetzner resources + the k3s cluster
│   ├── 02-platform/            # cert-manager + Rancher + backups + upgrade controller
│   └── 03-rke2-clusters/
│       ├── _template/          # tracked template for downstream clusters
│       └── clusters/           # generated RKE2 roots (entire directory is gitignored)
├── modules/
│   └── rke2-custom-cluster/    # shared Rancher + Hetzner implementation
├── scripts/
│   ├── fetch-kubeconfig.sh     # pull the kubeconfig and rewrite its API endpoint
│   ├── merge-kubeconfig.sh     # merge it into ~/.kube/config
│   ├── delete-kube-context.sh  # remove it from ~/.kube/config
│   └── etcd-snapshot.sh        # take / list etcd snapshots
└── docs/
    ├── backup-restore.md       # disaster-recovery runbook (includes a drill)
    ├── upgrade.md              # upgrade runbook
    └── troubleshooting.md      # start here when something is stuck
```

**Why two stacks?**
Terraform must be able to configure a provider *before* it starts running. The `helm` and
`kubernetes` providers need a kubeconfig — which only exists after stack 01 has finished.
Putting both in one stack creates a chicken-and-egg problem. Split apart, stack 01 builds the
cluster and emits a kubeconfig, stack 02 consumes it. This is the standard pattern.

Downstream RKE2 clusters add a third layer. Rancher must already be reachable before its
provider can create a custom cluster and return the node registration command. Every cluster
under `stacks/03-rke2-clusters/clusters/<name>` calls the same shared module but keeps a
separate state. The generated `clusters/` directory is gitignored because it contains
configuration and state,
so creating or destroying a second RKE2 cluster cannot replace the first cluster's state.

---

## Terraform in three minutes

**The core idea:** you *describe the desired end state* in `.tf` files. Terraform diffs that
against what actually exists in the cloud and works out what to change. It is not a script —
there is no execution order, only a dependency graph it derives from how resources reference
each other.

**Four kinds of file:**

| File | Role |
| --- | --- |
| `variables.tf` | Declares which knobs exist (like a function signature) |
| `terraform.tfvars` | The values you actually supply (**contains secrets, gitignored**) |
| other `*.tf` | The resource definitions themselves |
| `terraform.tfstate` | Terraform's ledger of what it has created. **Lose it and Terraform forgets everything and wants to rebuild it all** |

**Four commands:**

```bash
terraform init      # download providers (first run, or after changing provider versions)
terraform plan      # "what would happen if I ran this" — read-only, run it freely
terraform apply     # actually do it; shows the plan first and asks you to type yes
terraform destroy   # delete everything this stack created
```

**Reading a plan:**

```text
+ create      new resource
~ update      changed in place (no service impact)
-/+ replace   destroyed and recreated  ←←← stop and think when you see this
- destroy     removed
```

> ⚠️ The dangerous one here is `-/+ replace` on `hcloud_server.server` — that means Terraform
> wants to rebuild control-plane nodes, and all three at once wipes the cluster. This repo
> guards against the common cause with
> `lifecycle { ignore_changes = [user_data, ssh_keys, image] }`, because cloud-init only ever
> runs on first boot: editing it changes nothing on a running node, yet would still trigger a
> rebuild. When you genuinely want to roll a node, do it **one at a time**:
> `terraform apply -replace='hcloud_server.server[2]'`

**Where does state live?**
Locally, in `stacks/*/terraform.tfstate`. Fine for a single operator, but **back it up**, or
switch to a remote backend (S3 / Terraform Cloud). Losing state is painful to recover from.

---

## Prerequisites

### 1. Tools

```bash
brew install terraform kubectl helm jq
```

Terraform ≥ 1.6, kubectl, Helm 3, jq.

### 2. A Hetzner API token

Hetzner Cloud Console → your project → **Security** → **API tokens** → Generate API token →
permission **Read & Write** → copy it (shown only once).

### 3. An SSH key

**Use the key you already have.** Terraform needs two paths: the public key, which it uploads
to Hetzner and installs in root's `authorized_keys` on every node, and the matching private
key, which never leaves your machine — only `scripts/fetch-kubeconfig.sh` and
`scripts/etcd-snapshot.sh` use it to reach the nodes.

```bash
ls -l ~/.ssh/*.pub          # find what you already have
```

If your key lives at the default location there is nothing to configure. Otherwise point the
variables at it:

```hcl
# stacks/01-infra/terraform.tfvars
ssh_public_key_path  = "~/.ssh/my_key.pub"
ssh_private_key_path = "~/.ssh/my_key"
```

Ed25519 and RSA both work.

Only if you have no key at all:

```bash
ssh-keygen -t ed25519 -C "k3s-hetzner" -f ~/.ssh/id_ed25519
```

> If your private key has a passphrase, run `ssh-add ~/.ssh/my_key` once before
> `make apply`, otherwise the kubeconfig fetch stalls waiting for a prompt it cannot show you.

### 4. A domain

Rancher **requires a DNS hostname** — it cannot be reached by IP. Have something like
`rancher.yourdomain.com` ready, on a zone you can edit.

### 5. Hetzner Object Storage (for backups)

Object Storage is created manually because the `hcloud` Terraform provider does not manage S3
buckets or S3 credentials. In the same Hetzner project as the cluster:

1. Open **Object Storage** → **Create Bucket**.
2. **Location:** pick **Nuremberg**. The dialog lists cities, not codes — `nbg1` is Nuremberg
   (the default, Falkenstein, is `fsn1`). The suffix next to the name field should read
   `.nbg1.your-objectstorage.com`.
3. **Name:** must be globally unique. Use a `firstperson`-related name, for example
   `firstperson-backup-<unique-suffix>`. Object Lock **Disabled**, Visibility **Private**.
4. Open **Security** → **S3 credentials** and generate a credential pair. The dialog asks for a
   **Description** — it is the only label the pair ever gets. Name it after the bucket rather
   than the cluster, for example `firstperson-backup`: the credentials are scoped to the whole
   Object Storage account, and this bucket holds more than just the k3s and Rancher backups.
   Unlike the bucket name it does not have to be globally unique.
5. Immediately save both the access key and secret key in a password manager. The secret is
   shown only once and is required during disaster recovery.

Use Nuremberg unless you have a reason not to — it is where the cluster is created, and the
`*_s3_endpoint` / `*_s3_region` defaults in both stacks already point at `nbg1`. A different
location means changing all four of them, and the mismatch only surfaces at the first upload.

The Hetzner Cloud API token from prerequisite 2 cannot authenticate to Object Storage. The same
S3 credential pair and private bucket are used by both stacks; separate folder prefixes keep
the etcd snapshots and Rancher backups apart.

---

## Deploy

### Step 1 — Configure stack 01

```bash
cd stacks/01-infra
cp terraform.tfvars.example terraform.tfvars
code terraform.tfvars
```

Minimum you need to set:

```hcl
hcloud_token = "your Hetzner token"
cluster_name = "k3s-rancher"

# Lock SSH to your own addresses: curl -s https://ifconfig.me
# One entry per address, always /32 — Hetzner takes CIDR notation only.
ssh_allowed_cidrs = [
  "203.0.113.7/32",   # office
  "198.51.100.42/32", # admin 1, home
]


# etcd snapshots to Hetzner Object Storage (required - there is no local-only mode)
etcd_s3_endpoint   = "nbg1.your-objectstorage.com"
etcd_s3_region     = "nbg1"
etcd_s3_bucket     = "your-globally-unique-bucket-name"
etcd_s3_access_key = "..."
etcd_s3_secret_key = "..."
```

### Step 2 — Build the cluster

```bash
cd ../..            # back to the repo root
make init
make plan           # read what it intends to do
make apply          # type yes
```

Takes roughly **5–8 minutes**. Terraform will appear to hang on
`null_resource.kubeconfig` — that is it waiting for the first server to finish bootstrapping.
This is expected.

The cluster's kubeconfig is now at `./kubeconfig`. Use it directly:

```bash
export KUBECONFIG=$PWD/kubeconfig
kubectl get nodes -o wide
```

Or, if you already juggle other clusters, merge it into `~/.kube/config` so it becomes one
more context you can switch to:

```bash
make kubeconfig-merge
kubectl config use-context k3s-rancher
```

The merge backs up `~/.kube/config` first, leaves your other clusters and your current context
untouched, and is safe to re-run — same-named entries are replaced rather than duplicated, so
running it again after rebuilding the cluster just refreshes the credentials. The context takes
its name from `cluster_name`.

Either way, you should see three `Ready` nodes with roles `control-plane,etcd,master`:

```text
NAME                   STATUS   ROLES                       AGE   VERSION
k3s-rancher-server-1   Ready    control-plane,etcd,master   4m    v1.35.7+k3s1
k3s-rancher-server-2   Ready    control-plane,etcd,master   3m    v1.35.7+k3s1
k3s-rancher-server-3   Ready    control-plane,etcd,master   2m    v1.35.7+k3s1
```

> The rest of this README assumes `KUBECONFIG` points at the cluster. If you merged instead,
> either select the context first or add `--context k3s-rancher` to the kubectl commands.
>
> If nodes stay `NotReady` with a `node.cloudprovider.kubernetes.io/uninitialized` taint, the
> Hetzner CCM has not started — see [Troubleshooting](docs/troubleshooting.md).

**Save the join token — this matters:**

```bash
make token
```

Besides letting nodes join, this token encrypts confidential data inside etcd.
**Without it, an etcd snapshot cannot be restored.** Put it in your password manager.

### Step 3 — Point DNS at the load balancer

```bash
make outputs
```

Take `load_balancer_ipv4` and create:

```text
rancher.yourdomain.com.   A      <load_balancer_ipv4>
```

**Wait for DNS to propagate before continuing**, otherwise the Let's Encrypt challenge fails:

```bash
dig +short rancher.yourdomain.com
```

### Step 4 — Install Rancher

```bash
cd stacks/02-platform
cp terraform.tfvars.example terraform.tfvars
code terraform.tfvars
```

```hcl
rancher_hostname  = "rancher.yourdomain.com"
letsencrypt_email = "you@yourdomain.com"

backup_s3_bucket     = "your-globally-unique-bucket-name"
backup_s3_access_key = "..."
backup_s3_secret_key = "..."
```

```bash
cd ../..
make apply-platform
```

Takes **5–10 minutes** (cert-manager → Rancher → certificate issuance).

Check the certificate was issued:

```bash
kubectl -n cattle-system get certificate
# READY should be True
```

### Step 5 — Log in

```bash
make rancher-password
open https://rancher.yourdomain.com
```

User `admin`, with that password. Rancher forces a change on first login.

### Step 6 — Create an RKE2 cluster

First, create a Rancher API key from the user menu under **Account & API Keys**.
Then scaffold a Terraform root for the new cluster:

```bash
make new-rke2-cluster CLUSTER=rke2-vtafarm-production
```

This name is also used as the cluster name in Rancher and as its Terraform
directory name.

Edit the generated configuration:

```bash
code stacks/03-rke2-clusters/clusters/rke2-vtafarm-production/terraform.tfvars
```

At minimum, replace the Hetzner and Rancher credentials and restrict SSH
access:

```hcl
hcloud_token      = "your Hetzner token"
rancher_api_url   = "https://rancher.yourdomain.com"
rancher_token_key = "token-xxxxx:xxxxx"

# Hetzner location for all servers and the load balancer:
# fsn1 = Falkenstein, nbg1 = Nuremberg, hel1 = Helsinki,
# ash = Ashburn, hil = Hillsboro, sin = Singapore.
location = "nbg1"

# Hetzner server type for all RKE2 control-plane/etcd nodes.
server_count = 3
server_type  = "cx33"

# Reuse an existing SSH key from this Hetzner project.
ssh_key_name = "k3s-rancher-admin"

ssh_allowed_cidrs = [
  "203.0.113.7/32"
]
```

The directory name supplies `cluster_name`. `location` controls the Hetzner
location of every server and the cluster load balancer. Other settings use defaults,
including a dedicated Hetzner network, three `cx33` nodes, Ubuntu 24.04, and
RKE2 with Canal and Traefik. `ssh_key_name` selects an existing SSH key from
the same Hetzner project; this stack does not upload or duplicate the key.

Create the RKE2 cluster and its Hetzner hosts:

```bash
make init-rke2 CLUSTER=rke2-vtafarm-production
make plan-rke2 CLUSTER=rke2-vtafarm-production
make apply-rke2 CLUSTER=rke2-vtafarm-production
```

The default creates three nodes with the etcd, control-plane, and worker roles.
Its Terraform-managed load balancer forwards `80`, `443`, `6443`, and `9345`
to all server nodes over their private addresses. RKE2's default ingress
configuration binds the standard HTTP and HTTPS ports on those nodes.
Wait for `rke2-vtafarm-production` to become **Active** in Rancher Cluster
Management before continuing.

Write its Rancher-generated kubeconfig when it is Active and use it directly:

```bash
make kubeconfig-rke2 CLUSTER=rke2-vtafarm-production
export KUBECONFIG=$PWD/stacks/03-rke2-clusters/clusters/rke2-vtafarm-production/kubeconfig.yaml
kubectl get nodes
```

Or merge it into `~/.kube/config` alongside your other clusters:

```bash
make kubeconfig-merge-rke2 CLUSTER=rke2-vtafarm-production
```

#### Optional — Create more RKE2 clusters

Repeat Step 6 with a different unique name:

```bash
make new-rke2-cluster CLUSTER=rke2-vtafarm-staging
```

Destroy one downstream cluster without touching stack 01, stack 02, or other
RKE2 clusters:

```bash
make destroy-rke2 CLUSTER=rke2-vtafarm-production
```

---

## Testing

### Quick health check

```bash
make status
```

Shows nodes, etcd members, any non-Running pods, the Rancher deployment and certificates.

### Detailed verification

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

### HA failover test — do this once, before you rely on the cluster

This is the only way to know whether "HA" is actually HA.

```bash
# pick a node you are NOT connected to, and power it off
hcloud server poweroff k3s-rancher-server-3     # or use the Console
```

In another terminal:

```bash
watch kubectl get nodes
```

Expected behaviour:

| When | What happens |
| --- | --- |
| immediately | `kubectl` keeps working — the LB routes to the remaining two servers |
| ~40s | the node goes `NotReady` |
| ~5 min | its pods are evicted and rescheduled elsewhere |
| throughout | `https://rancher.yourdomain.com` stays available |

```bash
hcloud server poweron k3s-rancher-server-3
kubectl get nodes          # back to Ready within a minute or two
```

> **What if you kill a second node?** etcd loses quorum (1 of 3 is below the required
> `(3/2)+1 = 2`) and **the API server stops serving**. That is etcd behaving correctly, not a
> bug. Tolerating two simultaneous failures requires five servers.

---

## Backups

Two layers. Both are configured, and neither substitutes for the other:

| Layer | Tool | Covers | Use when |
| --- | --- | --- | --- |
| **etcd snapshot** | built into k3s | the entire Kubernetes datastore (every resource, including all of Rancher) | the cluster is broken, something was deleted by mistake, or you need to roll back |
| **Rancher backup** | rancher-backup operator | only Rancher's own CRDs, users and downstream cluster registrations | migrating Rancher to a different cluster |

Both upload to the same private Hetzner Object Storage bucket on a schedule, under different
folder prefixes.

### etcd snapshots

Every **6 hours** by default. Each node keeps 12 compressed snapshots locally (3 days), while
all three nodes share an S3 retention limit of 360 snapshots. At 4 snapshots per node per day,
that is 12 uploads per day and approximately 30 days of S3 history. Tune these values with the
`etcd_snapshot_*` / `etcd_s3_*` variables in `stacks/01-infra/terraform.tfvars`.

```bash
make snapshots            # list all snapshots (local + S3)
make snapshot             # take one right now
```

### Three things you must keep outside the cluster

A snapshot file on its own is not enough. Store these in a password manager or separate backup:

1. **The k3s token** — `make token`. It decrypts the bootstrap data inside every snapshot.
2. **Terraform state** — `stacks/*/terraform.tfstate`.
3. **The S3 credentials** — otherwise you cannot reach the backups you took.

### Restoring

The full procedure, including how to rehearse it, is in
**[docs/backup-restore.md](docs/backup-restore.md)**.

**Run the drill before you go live.** A backup you have never restored is not a backup.

---

## Upgrades

Three independent things. Recommended order: **k3s → Rancher → operating system**.

### 1. k3s

Handled by `system-upgrade-controller` — the
[approach k3s documents for automated upgrades](https://docs.k3s.io/upgrades/automated).
It is already installed and **pinned to an explicit version**, so nothing moves on its own.

```hcl
# stacks/02-platform/terraform.tfvars
k3s_target_version = "v1.35.8+k3s1"
```

```bash
make snapshot
make apply-platform
```

The controller works **one node at a time**: cordon → swap the binary → restart → wait for
Ready → next node.

```bash
kubectl -n system-upgrade get jobs -w
kubectl get nodes -w
```

> **Which version?** It must satisfy the Rancher chart's `kubeVersion` — 2.14.x means
> **< 1.36.0-0**, i.e. v1.33 / v1.34 / v1.35. List the current channel heads with:
>
> ```bash
> curl -s https://update.k3s.io/v1-release/channels | jq -r '.data[] | "\(.id)\t\(.latest)"'
> ```
>
> The Plan pins an exact version on purpose. A k3s release channel would work here too, but
> it would upgrade the cluster past what the installed Rancher chart accepts, unattended.

### 2. Rancher

```hcl
# stacks/02-platform/terraform.tfvars
rancher_chart_version = "2.14.4"
```

```bash
make snapshot        # rollback for a failed Rancher upgrade IS the etcd snapshot
make apply-platform
```

Rancher cannot skip minor versions (no 2.12 → 2.14; go 2.12 → 2.13 → 2.14).

### 3. Operating system

Upgrade to the next Ubuntu LTS with a rolling replacement:

```bash
make upgrade-os TARGET_IMAGE=ubuntu-26.04
```

Full procedures and a checklist: **[docs/upgrade.md](docs/upgrade.md)**.

---

## Day-2 operations

```bash
make help                # list every target
make status              # cluster health overview
make outputs             # LB IPs, node IPs, DNS records to create
make ssh                 # SSH into the first control-plane node
make token               # the k3s token
make rancher-password    # Rancher bootstrap password
make snapshot            # on-demand etcd snapshot
make snapshots           # list snapshots
make kubeconfig          # re-fetch the kubeconfig
make kubeconfig-merge    # merge it into ~/.kube/config as a switchable context
make kubeconfig-delete   # delete it from ~/.kube/config
```

### Growing the cluster

Every node is a control-plane and etcd member, so scaling means adding servers — and the
count must stay **odd** for etcd quorum. Going from 3 to 5 raises the tolerated simultaneous
failures from one to two:

```hcl
# stacks/01-infra/terraform.tfvars
server_count = 5
```

```bash
make snapshot        # etcd membership changes; have a restore point first
make apply
kubectl get nodes -w
```

The new nodes wait for the existing ones, join through the load balancer, and pick up the
firewall and load balancer target by label. Nothing else needs changing.

> This repo has no separate worker pool by design — with everything schedulable there is one
> node type to reason about. If workloads ever outgrow that, the change is a second
> `hcloud_server` resource with `INSTALL_K3S_EXEC=agent` in its bootstrap env, plus an
> `agent-plan` for the upgrade controller.

---

## Troubleshooting

When a node is stuck, always start with the bootstrap log:

```bash
ssh root@<node-ip> 'tail -100 /var/log/cloud-init-output.log'
ssh root@<node-ip> 'journalctl -u k3s -n 200 --no-pager'
```

**[docs/troubleshooting.md](docs/troubleshooting.md)** covers:

- nodes stuck `NotReady` with the `uninitialized` taint (CCM did not start)
- Let's Encrypt certificate never issued
- the second and third servers fail to join
- `terraform plan` wants to replace server nodes
- Rancher pods in `CrashLoopBackOff`
- load balancer targets reported unhealthy

---

## Cost

Monthly cost for `nbg1` with the defaults:

| Item | Unit | Qty | / month |
| --- | --- | --- | --- |
| `cx23` (2 vCPU / 4 GB / 40 GB NVMe) | €6.59 | 3 | €19.77 |
| Load Balancer `lb11` | €8.99 | 1 | €8.99 |
| Public IPv4 | €0.60 | 3 | €1.80 |
| **Hetzner compute total** | | | **€30.56** |
| Hetzner Object Storage | €7.79 | 1 account | €7.79 |
| **Estimated total** | | | **€38.35** |

Scaling options:

- moving up to `cx33` (4 vCPU / 8 GB) costs about €11/month more in total and removes the
  memory pressure described above — the obvious first step if Rancher starts getting OOMKilled
- adding a fourth and fifth server costs €13.18/month and buys tolerance for two
  simultaneous node failures instead of one

---

## Teardown

Destroy only stack 02 (cert-manager, Rancher, backups, and the upgrade
controller) while keeping the stack 01 k3s infrastructure and independently
managed RKE2 infrastructure:

```bash
make destroy-platform
```

Destroy both stack 02 and stack 01:

```bash
make destroy
```

Destroys stack 02 (Helm releases) first, then stack 01 (Hetzner resources).

> The order matters. Destroying the infrastructure first leaves stack 02's state believing its
> releases still exist. If that happens, clear the entries with
> `terraform -chdir=stacks/02-platform state rm <resource>`.

Afterwards, check the Hetzner Console for leftover Volumes. PVs created by the CSI driver are
not Terraform-managed: those with `reclaimPolicy: Delete` disappear on their own, but `Retain`
volumes stay and keep billing.

---

## Kubeconfig context

Merge the generated kubeconfig into `~/.kube/config`:

```bash
make kubeconfig-merge
```

Delete it later:

```bash
make kubeconfig-delete
```

Deletion creates a backup first and preserves cluster/user entries still used by other contexts.

---

## References

- [k3s — High Availability with Embedded etcd](https://docs.k3s.io/datastore/ha-embedded)
- [k3s — Fixed Registration Address](https://docs.k3s.io/datastore/ha)
- [k3s — Networking Requirements](https://docs.k3s.io/installation/requirements)
- [k3s — etcd Snapshot CLI](https://docs.k3s.io/cli/etcd-snapshot)
- [k3s — Automated Upgrades](https://docs.k3s.io/upgrades/automated)
- [Rancher — Install on a Kubernetes Cluster](https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/install-upgrade-on-a-kubernetes-cluster)
- [Rancher — Support Matrix](https://www.suse.com/suse-rancher/support-matrix/all-supported-versions/)
- [Hetzner Cloud Terraform Provider](https://registry.terraform.io/providers/hetznercloud/hcloud/latest/docs)
- [hcloud-cloud-controller-manager](https://github.com/hetznercloud/hcloud-cloud-controller-manager)

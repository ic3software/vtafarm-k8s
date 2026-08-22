# vtafarm on RKE2 — deployment guide

This guide deploys vtafarm on Hetzner Cloud. You start with an empty Hetzner project and finish
with a running application. It builds five layers, in this order:

1. a 3-node high-availability **k3s** cluster
2. **Rancher**, running on that k3s cluster
3. an **RKE2** cluster that Rancher creates for a farm
4. the platform inside that cluster: **cert-manager**, **Longhorn** and **HashiCorp Vault**
5. the vtafarm frontend and API

Each layer is one OpenTofu stack. You build layers 1 and 2 once. Layers 3 to 5 are one farm, so
repeat steps 6 to 8 for every farm you need. Vault keeps the master seed of every VTA encrypted
and separated per user, which is what makes a farm safe enough to run vtafarm on. See
[docs/vault.md](docs/vault.md).

## Contents

- [Architecture](#architecture)
- [Deploy](#deploy)
  - [Prerequisites](#prerequisites)
  - [Step 1 — Configure stack 01](#step-1--configure-stack-01)
  - [Step 2 — Build the cluster](#step-2--build-the-cluster)
  - [Step 3 — Point DNS at the load balancer](#step-3--point-dns-at-the-load-balancer)
  - [Step 4 — Install Rancher](#step-4--install-rancher)
  - [Step 5 — Log in](#step-5--log-in)
  - [Step 6 — Create an RKE2 cluster](#step-6--create-an-rke2-cluster)
  - [Step 7 — Install the platform layer](#step-7--install-the-platform-layer)
  - [Step 8 — Install the applications](#step-8--install-the-applications)
- [Runbooks](#runbooks)

---

## Architecture

### Management cluster — k3s + Rancher

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

### Downstream cluster — RKE2 + the vtafarm platform

The farm Vault stores the master seed of every VTA. It cannot unseal itself after a restart, so
a second Vault does that for it. This transit Vault runs on one node and holds one key:

```text
                          internet
                              │
                ┌─────────────▼───────────────┐
                │  Hetzner Load Balancer      │
                │    :6443  Kubernetes API    │  → servers
                │    :9345  RKE2 registration │  → servers
                │    :80 :443  Traefik        │  → all nodes
                └─────────────┬───────────────┘
  ┌───────────────────────────┴─────────────────────────────┐
  │         Hetzner private network 10.10.1.0/24            │
  │                                                         │
  │   server-1          server-2          server-3          │
  │   ┌──────────┐      ┌──────────┐      ┌──────────┐      │
  │   │ RKE2     │      │ RKE2     │      │ RKE2     │      │
  │   │ + etcd   │◄────►│ + etcd   │◄────►│ + etcd   │      │
  │   │ Longhorn │◄────►│ Longhorn │◄────►│ Longhorn │      │
  │   │ vault-0  │◄────►│ vault-1  │◄────►│ vault-2  │      │
  │   └──────────┘      └──────────┘      └──────────┘      │
  │      namespace vault — Raft, HA, auto-unsealed          │
  │                          │                              │
  │                          │ seal "transit"               │
  │                          ▼                              │
  │   ┌───────────────────────────────────────────┐         │
  │   │ namespace vault-transit                   │         │
  │   │   vault-transit-0   holds `autounseal`    │         │
  │   │   Shamir-sealed, unsealed by hand         │         │
  │   │   NetworkPolicy: reachable from ns/vault  │         │
  │   └───────────────────────────────────────────┘         │
  └─────────────────────────────────────────────────────────┘
```

### Five stacks

A stack cannot run until the stack before it exists. You therefore apply them in order:

| Stack | Waits for |
| --- | --- |
| `01-infra` | nothing |
| `02-rancher` | stack 01's kubeconfig |
| `03-rke2-clusters` | Rancher to be reachable |
| `04-vtafarm-platform` | stack 03's cluster to be Active |
| `05-vtafarm-app` | stack 04's Vault to be bootstrapped |

Stacks 03, 04 and 05 keep one directory per cluster, under `clusters/<name>`. Each directory
has its own state file. Creating or destroying one cluster does not affect the others.

The full directory tree and the reasons behind this layout are in
[docs/design-decisions.md](docs/design-decisions.md).

---

## Deploy

### Prerequisites

Collect all of this before you start.

1. **Tools** — `brew install opentofu kubectl helm jq`. OpenTofu must be 1.12 or newer
2. **Hetzner API token**, Read & Write — Console → Security → API tokens. Shown once
3. **SSH key pair** — the one you already use, or `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519`
4. **A DNS zone you can edit** — at your registrar. The farm domain in step 8 must be on
   Cloudflare, see below
5. **A private Object Storage bucket** in Nuremberg (`nbg1`) — Console → Object Storage →
   Create Bucket. The name must be globally unique. Object Lock disabled, Visibility private
6. **S3 credential pair** — Console → Security → S3 credentials. The secret is shown once

vtafarm itself, in step 8, also needs:

1. **Cloudflare API token and zone ID** — from the Cloudflare dashboard, for the zone of your
   domain. vtafarm creates tenant domains automatically, and Cloudflare is the only DNS
   provider it supports today
2. **`did:key` keypair** — `make gen-keypair` in the vtafarm-api repo

### Step 1 — Configure stack 01

```bash
cd stacks/01-infra
cp terraform.tfvars.example terraform.tfvars
code terraform.tfvars
```

Go through every value in the file and read the comments above them. They say what each value
does and which ones you have to fill in. Continue with step 2 when the file is complete.

### Step 2 — Build the cluster

```bash
cd ../..
make init
make apply
```

This takes about **5–8 minutes**. OpenTofu looks stuck at `null_resource.kubeconfig`. It is
waiting for the first server to finish its bootstrap, so this is normal.

OpenTofu writes the kubeconfig to `stacks/01-infra/kubeconfig.yaml`:

```bash
export KUBECONFIG=$PWD/stacks/01-infra/kubeconfig.yaml
kubectl get nodes -o wide
```

You can also merge it into `~/.kube/config` and use it as one more context:

```bash
make kubeconfig-merge
kubectl config use-context k3s-rancher
```

In both cases you should see three `Ready` nodes with the roles
`control-plane,etcd,master`:

```text
NAME                   STATUS   ROLES                       AGE   VERSION
k3s-rancher-server-1   Ready    control-plane,etcd,master   4m    v1.35.7+k3s1
k3s-rancher-server-2   Ready    control-plane,etcd,master   3m    v1.35.7+k3s1
k3s-rancher-server-3   Ready    control-plane,etcd,master   2m    v1.35.7+k3s1
```

**Save the join token:**

```bash
make token
```

Store it in your password manager now. The token lets new nodes join, and it also encrypts the
secret data inside etcd, so **you cannot restore an etcd snapshot without it**.

### Step 3 — Point DNS at the load balancer

```bash
make outputs
```

Take the `load_balancer_ipv4` value and create this record:

```text
rancher.yourdomain.com.   A      <load_balancer_ipv4>
```

**Wait until DNS has propagated before you continue.** If you do not, the Let's Encrypt
challenge fails:

```bash
dig +short rancher.yourdomain.com
```

### Step 4 — Install Rancher

```bash
cd stacks/02-rancher
cp terraform.tfvars.example terraform.tfvars
code terraform.tfvars
```

Go through every value in the file and read the comments above them. Reuse the bucket and the
S3 credentials from step 1.

```bash
cd ../..
make apply-rancher
```

This takes **5–10 minutes**: cert-manager first, then Rancher, then the certificate. `READY`
must be `True`:

```bash
kubectl -n cattle-system get certificate
```

### Step 5 — Log in

```bash
make rancher-password
open https://rancher.yourdomain.com
```

Log in as `admin` with that password. Rancher asks you to change it at the first login.

### Step 6 — Create an RKE2 cluster

Create a Rancher API key in the user menu, under **Account & API Keys**. Then generate an
OpenTofu directory for the new cluster. The name you pass is both the cluster name in Rancher
and the directory name:

```bash
make new-rke2-cluster CLUSTER=rke2-vtafarm-production
code stacks/03-rke2-clusters/clusters/rke2-vtafarm-production/terraform.tfvars
```

Go through every value in the file and read the comments above them. The scaffold already
wrote `terraform.tfvars` for you, so there is nothing to copy.

```bash
make init-rke2  CLUSTER=rke2-vtafarm-production
make apply-rke2 CLUSTER=rke2-vtafarm-production
```

Wait until the cluster is **Active** in Rancher, under Cluster Management. The first apply
stores an empty, unusable `kube_config`, because Rancher is still creating the cluster while
OpenTofu finishes. Refresh the state once the cluster is Active:

```bash
make refresh-rke2 CLUSTER=rke2-vtafarm-production
```

Then write the kubeconfig and use it directly:

```bash
make kubeconfig-rke2 CLUSTER=rke2-vtafarm-production
export KUBECONFIG=$PWD/stacks/03-rke2-clusters/clusters/rke2-vtafarm-production/kubeconfig.yaml
kubectl get nodes
```

Or merge it into `~/.kube/config` and use it as one more context:

```bash
make kubeconfig-merge-rke2 CLUSTER=rke2-vtafarm-production
kubectl config use-context rke2-vtafarm-production
```

Either way the file lands in the cluster's directory, where stacks 04 and 05 read it.

To add a second cluster, repeat this step with a different name, for example
`make new-rke2-cluster CLUSTER=rke2-vtafarm-staging`. The two directories are independent.

### Step 7 — Install the platform layer

This step installs the platform inside the RKE2 cluster: cert-manager, Longhorn and the two
Vaults.

Use the same cluster name as in step 6. This stack reads the kubeconfig from that cluster's
directory, so the two names must match.

```bash
make new-vtafarm-platform CLUSTER=rke2-vtafarm-production
code stacks/04-vtafarm-platform/clusters/rke2-vtafarm-production/terraform.tfvars
```

The defaults work as they are. Open the file only if you want a different Vault or Longhorn
setup, and read the comments before you change anything.

```bash
make init-vtafarm-platform  CLUSTER=rke2-vtafarm-production
make apply-vtafarm-platform CLUSTER=rke2-vtafarm-production
```

This takes **5–10 minutes**.

```bash
make vault-status CLUSTER=rke2-vtafarm-production
```

**Both Vaults start sealed, and a sealed Vault reports itself as not ready.** The transit pod
shows `0/1`. The farm pods stay in `CreateContainerConfigError`, because they wait for a secret
that does not exist yet. This is the expected state after this apply. It is not a failure.

Initializing and unsealing a Vault produces recovery keys and root tokens. These must never be
written into OpenTofu state, so you run those steps by hand. Point kubectl at the cluster first:

```bash
export KUBECONFIG=$PWD/stacks/03-rke2-clusters/clusters/rke2-vtafarm-production/kubeconfig.yaml
```

1. Init the transit Vault. This writes the Shamir keys and its root token to
   `vault-init-transit.json`:

   ```bash
   kubectl exec -n vault-transit vault-transit-0 -- \
     vault operator init -key-shares=5 -key-threshold=3 -format=json > vault-init-transit.json
   ```

2. Unseal it. Run this **three** times, with a different Shamir key each time:

   ```bash
   kubectl exec -it -n vault-transit vault-transit-0 -- vault operator unseal
   ```

3. Create the unseal token for the farm Vault. Paste the root token from
   `vault-init-transit.json` after the `=`:

   ```bash
   export VAULT_TOKEN=
   make vault-bootstrap CLUSTER=rke2-vtafarm-production TARGET=transit
   ```

4. Restart the farm pods so they read the new token:

   ```bash
   kubectl -n vault rollout restart statefulset/vault
   ```

5. Init the farm Vault. Its peers unseal themselves from here on:

   ```bash
   kubectl exec -n vault vault-0 -- vault operator init -format=json > vault-init-farm.json
   ```

6. Configure it for vtafarm-api. Paste the root token from `vault-init-farm.json`:

   ```bash
   export VAULT_TOKEN=
   make vault-bootstrap CLUSTER=rke2-vtafarm-production TARGET=farm
   ```

> ⚠️ Move both `vault-init-*.json` files into your password manager now, then delete the local
> copies. They hold the recovery keys and the root tokens. Git ignores them, which is not the
> same as safe. Every cluster has its own keys, and a Vault snapshot is worthless without them.

The full procedure, the tenant isolation model and the day-2 operations are in
[docs/vault.md](docs/vault.md).

### Step 8 — Install the applications

This step installs the vtafarm applications: the frontend and the API.

```bash
make new-vtafarm-app CLUSTER=rke2-vtafarm-production
code stacks/05-vtafarm-app/clusters/rke2-vtafarm-production/terraform.tfvars
```

Go through every value in the file and read the comments above them. `domain` drives every
hostname the farm serves.

Create the two A records next. Both point at the load balancer of the cluster. cert-manager
cannot issue the certificate until these names resolve:

```text
vtafarm.yourdomain.com.       A   <cluster_ingress_ip>
vtafarm-api.yourdomain.com.   A   <cluster_ingress_ip>
```

```bash
make init-vtafarm-app  CLUSTER=rke2-vtafarm-production
make apply-vtafarm-app CLUSTER=rke2-vtafarm-production
```

This stack generates the JWT secret and the database password instead of taking them from you.
They exist only in this stack's state file, so back that file up.

```bash
make outputs-vtafarm-app CLUSTER=rke2-vtafarm-production
```

Create the first admin:

```bash
export KUBECONFIG=$PWD/stacks/03-rke2-clusters/clusters/rke2-vtafarm-production/kubeconfig.yaml
kubectl exec -it deployment/vtafarm-api -- ./enroll
```

Or, if you merged the kubeconfig in step 6, switch to that context instead:

```bash
kubectl config use-context rke2-vtafarm-production
kubectl exec -it deployment/vtafarm-api -- ./enroll
```

The farm is now running. Everything after this point is a runbook.

---

## Runbooks

| Document | Covers |
| --- | --- |
| [docs/testing.md](docs/testing.md) | health checks, detailed verification, the HA failover test |
| [docs/operations.md](docs/operations.md) | day-2 `make` targets, kubeconfig contexts, adding nodes, what is backed up |
| [docs/backup-restore.md](docs/backup-restore.md) | disaster recovery, four failure scenarios, and a drill |
| [docs/upgrade.md](docs/upgrade.md) | how to upgrade k3s, Rancher, cert-manager, the OS, a vtafarm release and the providers |
| [docs/vault.md](docs/vault.md) | Vault init, unseal, bootstrap, the isolation model and day-2 tasks |
| [docs/vault-upgrade.md](docs/vault-upgrade.md) | how to upgrade both Vaults and drain a node |
| [docs/troubleshooting.md](docs/troubleshooting.md) | read this first when something is stuck |
| [docs/design-decisions.md](docs/design-decisions.md) | the repository layout, and why the topology and the version pins are what they are |
| [docs/teardown.md](docs/teardown.md) | how to destroy one layer, one cluster, or everything |
| [docs/opentofu-primer.md](docs/opentofu-primer.md) | a short introduction to OpenTofu, if it is new to you |
| [docs/cost.md](docs/cost.md) | the monthly cost, and what each scaling step adds |

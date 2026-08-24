# Vault Runbook

Two Vaults run on every downstream RKE2 cluster, installed by stack 04.

| | farm Vault | transit Vault |
| --- | --- | --- |
| namespace | `vault` | `vault-transit` |
| release | `vault` | `vault-transit` |
| topology | 3 peers, Raft, HA | 1 pod, file storage |
| holds | every VTA's master seed | one `autounseal` key, no tenant data |
| unseals | automatically, against transit | **by hand**, Shamir keys |
| reachable at | `https://vault.vault.svc:8200` | `https://vault-transit.vault-transit.svc:8200` |

The transit Vault exists so the farm's pods never block on a human after a restart. It is the
root of the unseal chain, which is why it is the one thing still unsealed manually.

> An in-cluster transit Vault does **not** protect against a full compromise of a running
> cluster — the token that unwraps the farm's root key lives in that same cluster. It protects
> data at rest and removes the manual unseal on every pod restart. Moving to a cloud KMS later
> is a swap of the `seal` stanza in `modules/vtafarm-platform/templates/vault-values.yaml.tftpl`,
> after which the transit Vault can be deleted.

---

## Why init and unseal are not in OpenTofu

`vault operator init` returns the recovery keys and the initial root token. Anything OpenTofu
learns, OpenTofu writes to state — and state here is a local file that already holds enough.
Those two steps therefore stay manual, and everything downstream of them is a script.

That splits the work cleanly:

- **OpenTofu owns the declarative layer** — namespaces, cert-manager, Longhorn, the TLS
  certificate chain, both Helm releases, the NetworkPolicy.
- **You own the keys** — `vault operator init` and `vault operator unseal`.
- **`scripts/vault-bootstrap.sh` owns the configuration** — mounts, auth methods, policies, and
  the credentials it writes straight into Kubernetes Secrets rather than printing.

---

## First install

Stack 04 must already be applied for the cluster (`make apply-vtafarm-platform CLUSTER=<name>`). Point
`kubectl` at that cluster first:

```bash
export KUBECONFIG=$PWD/stacks/03-rke2-clusters/clusters/<name>/kubeconfig.yaml
```

### 1. The pods are sealed, and that is correct

```bash
make vault-status CLUSTER=<name>
```

The transit pod is `Running` but `0/1` — sealed Vaults report not ready. The farm pods sit in
`CreateContainerConfigError`, waiting for a secret that step 3 creates. Neither is a failure.

### 2. Initialize and unseal the transit Vault

It has no auto-unseal — it is what provides auto-unseal — so this is real Shamir key handling:

```bash
kubectl exec -n vault-transit vault-transit-0 -- \
  vault operator init -key-shares=5 -key-threshold=3 -format=json > vault-init-transit.json
```

> ⚠️ That file holds five unseal keys and the root token. Move it into a password manager and
> delete the local copy. It is gitignored; that is not the same as safe. Without it you cannot
> unseal this Vault again, and without this Vault the farm cannot unseal either.

Unseal with three of the five keys:

```bash
kubectl exec -it -n vault-transit vault-transit-0 -- vault operator unseal   # ×3, one key each
```

The pod goes `1/1`. Repeat the unseal after any restart of this pod.

### 3. Bootstrap transit, then restart the farm

```bash
export VAULT_TOKEN=        # root token from vault-init-transit.json
make vault-bootstrap CLUSTER=<name> TARGET=transit
```

This enables the transit engine, creates the `autounseal` key, mints an orphan periodic token
and stores it as the `vault-transit-token` secret in the `vault` namespace. The farm pods were
waiting for exactly that:

```bash
kubectl -n vault rollout restart statefulset/vault
```

### 4. Initialize the farm Vault

With auto-unseal in place this returns **recovery** keys rather than unseal keys, and the peers
unseal themselves:

```bash
kubectl exec -n vault vault-0 -- vault operator init -format=json > vault-init-farm.json
```

> ⚠️ Same handling as before: password manager, then delete the local copy. Recovery keys are
> what let you regenerate a root token later.

Peers auto-join through the `retry_join` stanzas — no manual `vault operator raft join`. All
three pods should reach `1/1`:

```bash
kubectl -n vault get pods
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=<root> vault operator raft list-peers
```

### 5. Bootstrap the farm Vault

```bash
export VAULT_TOKEN=        # root token from vault-init-farm.json
make vault-bootstrap CLUSTER=<name> TARGET=farm
```

This enables the audit device, KV v2 at `secret/`, the Kubernetes auth method, AppRole, and
writes the `vtafarm-api-admin` policy plus the API's role. The resulting credentials go into
the `vtafarm-api-vault` secret in the `default` namespace — `role_id` is printed, `secret_id`
is not. Point the API at `VAULT_ADDR=https://vault.vault.svc:8200`.

Set `API_SECRET_NS` if vtafarm-api runs somewhere other than `default`.

### The audit trail lives on stdout

Vault refuses every request once an audit device cannot write, so a PersistentVolume for the
audit log is a liability: it fills, and Vault stops. The device therefore writes to the pods'
stdout, and kubelet's container-log rotation bounds and prunes it — sized by
`container-log-max-size` and `container-log-max-files` in the RKE2 cluster config, currently
100Mi across 5 files per container.

```bash
kubectl -n vault logs vault-0 | grep '"type":"request"'
```

Only the active peer serves requests, so that is where the trail accumulates. The window is
finite by design; ship the logs off-cluster if you ever need to retain them longer.

---

## The isolation model

One Vault serves every tenant. Separation is enforced by Vault, not by running one Vault per
user:

- **one policy and one Kubernetes-auth role per user namespace** — `vta-user-<userID>`
- **one seed path per session** — `secret/data/vta/user-<userID>/session-<sessionID>/master-seed`

```hcl
# policy vta-user-abc123, created at runtime by vtafarm-api
path "secret/data/vta/user-abc123/*"     { capabilities = ["read","create","update","delete"] }
path "secret/metadata/vta/user-abc123/*" { capabilities = ["read","delete"] }
```

Vault object count is therefore O(users), not O(sessions). Each tenant pod authenticates with
its ServiceAccount JWT; the role binds `bound_service_account_namespaces` to that tenant's
namespace alone.

`vault-bootstrap.sh farm` only grants vtafarm-api the *ability* to provision tenants. The API
creates the per-user policy and role at runtime, and `vta setup` writes the seed.

> The `vtafarm-api-admin` policy deliberately has **no read capability** on any seed path. The
> API provisions and tears down access; it never reads a tenant's secret. When
> `EnsureUserAccess` grows a new KV prefix, the matching delete grant has to be added to that
> policy in `scripts/vault-bootstrap.sh` as well — the components hold the per-user token while
> the API holds the AppRole, so a prefix added to one and not the other leaves secrets nobody
> can delete.

---

## Day-2

### Reaching the UI

Both Vaults serve their UI on the same HTTPS listener, and neither Service is exposed outside
the cluster. Use a port-forward:

```bash
kubectl port-forward -n vault svc/vault-ui 8200:8200
# https://127.0.0.1:8200/ui/
```

The certificate is signed by the internal CA, so the browser warns. Import the CA to silence it:

```bash
kubectl get secret -n vault vault-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > vault-ca.crt
```

Log in with a token. Do not use the root token for routine work, and never publish a secrets
store's UI through an ingress or LoadBalancer.

### Rotating the API credentials

Re-running the farm bootstrap issues a fresh `secret_id` and updates the secret in place:

```bash
make vault-bootstrap CLUSTER=<name> TARGET=farm
```

Use `SKIP_SECRET_ID=1` to update the policy or role without rotating the credential.

### Backups

The etcd snapshots in stack 01 cover the **management** cluster. They do not contain this Vault
— it lives on a downstream cluster with its own etcd. Snapshot Raft separately:

```bash
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=<root> \
  vault operator raft snapshot save /tmp/vault.snap
kubectl cp vault/vault-0:/tmp/vault.snap ./vault.snap
```

A snapshot is useless without the recovery keys, and the farm's snapshot is useless without a
transit Vault holding the same `autounseal` key. Keep both key sets outside the cluster.

### Upgrading the chart

Bump `vault_chart_version` in the cluster's `terraform.tfvars`, read the upstream changelog,
then `make apply-vtafarm-platform CLUSTER=<name>`. The apply only stages it: the chart defaults to
`updateStrategyType: OnDelete`, so nothing restarts until the pods are deleted by hand. Transit
comes back sealed and needs unsealing before the farm pods can auto-unseal from it, so the order
and the full procedure are in [`vault-upgrade.md`](vault-upgrade.md).

### Scaling the peers

`vault_replicas` must stay odd, and the chart's pod anti-affinity is **hard**: one Vault pod per
node. Asking for more peers than the cluster has schedulable nodes leaves the extras `Pending`
forever. The `retry_join` stanzas are generated from this value, so they cannot drift out of
sync with it.

---

## When something is stuck

| Symptom | Cause |
| --- | --- |
| farm pods in `CreateContainerConfigError` | the `vault-transit-token` secret does not exist yet — run the transit bootstrap, then `rollout restart statefulset/vault` |
| pods `Running` but `0/1` forever | the Vault is sealed. The transit one needs manual unsealing; the farm one means auto-unseal is failing — check the transit Vault is unsealed and reachable |
| pods stuck `ContainerCreating` | the `vault-tls` secret is missing. `kubectl -n vault get certificate` and check cert-manager is up |
| farm peers `Pending` | more `vault_replicas` than schedulable nodes; the anti-affinity rule is hard |
| PVCs `Pending` | Longhorn is not ready, or `longhorn_replica_count` exceeds the node count |
| `tofu apply` hangs on a Vault release | `wait` was set to true somewhere — a sealed Vault never reports ready, so the apply cannot succeed |

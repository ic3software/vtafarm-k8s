# Cluster Migration Runbook

Moving a live farm off a cluster this repository did not build, onto one it did. The worked
example is `k8s-fpp-production` → `rke2-vtafarm-production`, but nothing below is specific to
those two names.

`scripts/migrate-cluster.sh` does the mechanical parts. This document is the part it cannot do:
deciding what has to be identical on the new cluster, and in what order to move.

> **Read [§2](#2-what-must-be-identical) before you apply stack 05 on the new cluster.** Three
> of its values are not free choices, and one of them cannot be changed afterwards without
> breaking every tenant that already exists.

---

## Contents

- [1. What moves](#1-what-moves)
- [2. What must be identical](#2-what-must-be-identical)
- [3. Before the window](#3-before-the-window)
- [4. The cutover](#4-the-cutover)
- [5. Verify](#5-verify)
- [6. Rollback](#6-rollback)
- [7. Decommissioning the old cluster](#7-decommissioning-the-old-cluster)
- [8. Why the Vault is copied rather than restored](#8-why-the-vault-is-copied-rather-than-restored)
- [9. Common problems](#9-common-problems)

---

## 1. What moves

A farm is four kinds of state, and each one moves differently.

| State | Where it lives | How it moves |
| --- | --- | --- |
| accounts, sessions, passkeys | PostgreSQL, one PVC in `default` | `pg_dump` streamed into `pg_restore` |
| every VTA's master seed | the farm Vault's KV store | read from one Vault, written to the other |
| per-tenant Vault access | policies and kubernetes-auth roles named `vta-user-*` | copied object by object |
| a tenant's own data | one PVC per component, in `vtafarm-user-<id>` | `tar` streamed between two helper pods |

Two things deliberately do **not** move:

- **The Vault's keys.** The new cluster is initialized normally and keeps its own recovery keys,
  root token and transit key. The old `vault-init-*.json` files unlock nothing on it.
  [§8](#8-why-the-vault-is-copied-rather-than-restored) explains the trade.
- **Kubernetes-generated identity.** ClusterIPs, PV names, UIDs, ReplicaSet history. The script
  strips them; the new cluster mints its own.

And one thing that cannot move at all:

> **The domain stays the same.** A VTA's identity is a `did:webvh`, which is a hostname, and a
> user's passkey is bound to `WEBAUTHN_RP_ID`, which is also a hostname. Serve the farm on a
> different domain and every DID stops resolving and every passkey stops working. A farm on a
> new domain is a new farm. The cutover is therefore a **DNS change**, and everything in this
> runbook exists to have the new cluster ready before that change is made.

---

## 2. What must be identical

Fill these into `stacks/05-vtafarm-app/clusters/<new>/terraform.tfvars` **before**
`make apply-vtafarm-app`. Read the current values off the old cluster:

```bash
kubectl --context <old> -n default get secret vtafarm-api-secrets \
  -o jsonpath='{.data.DID_HOSTING_DID}' | base64 -d
```

| Value | On the new cluster | Why |
| --- | --- | --- |
| `domain` | **identical** | every DID and every passkey is a hostname under it |
| `cloudflare_zone_id` | **identical** | it is the same zone; the API writes tenant records into it |
| `cloudflare_api_token` | same rights on that zone | a new token is fine, the same permissions are not optional |
| `did_hosting_did` | **identical** | see below |
| `did_hosting_private_key` | **identical** | it is the key behind that DID |
| `monitor_token` | identical, or update UptimeRobot | it is a shared secret with whatever polls `/api/v1/monitor/*` |
| `vtafarm_version`, `vtafarm_api_version` | identical to what the old cluster runs | migrate, then upgrade — never both at once |
| `cluster_ingress_ip` | **must differ** | it is the new load balancer, and the API stamps it into every tenant A record it creates from now on |
| `namespace` | identical (`default`) | the Vault bootstrap writes the API's credentials there |
| `storage_class` | free | the default `longhorn-retain` is right |

**`did_hosting_did` is the one that cannot be fixed later.** It is vtafarm-api's own identity,
and every DID-hosting daemon a `full_stack` tenant already runs has that DID enrolled in its ACL
with `role=admin`. Hand the new API a fresh keypair and it is a stranger to every tenant that
already exists — it can create new ones and administer none of the old ones. The enrollment is
inside the tenant's own PVC, so re-applying stack 05 does not repair it.

### Two values you may let change

- **The JWT signing secret.** Stack 05 generates it (`random_password.jwt`), so the new cluster
  gets a different one and every signed-in session is invalidated. Users log in again; passkeys,
  invitation links and admin enrollment tokens are unaffected, because those are rows in the
  database rather than signed tokens. Accept it unless a re-login is genuinely unacceptable, in
  which case carry the old value into state before the first apply:

  ```bash
  #  the leading space keeps the secret out of shell history
   tofu -chdir=stacks/05-vtafarm-app/clusters/<new> import \
    'module.vtafarm_app.random_password.jwt' '<the old JWT_SECRET>'
  ```

- **The PostgreSQL password.** Also generated, and it does **not** need to match. The database
  moves as a logical dump — SQL statements, not a filesystem — so it is replayed into a server
  that `initdb` already created with the new cluster's own password. Both the server and the API
  read that one secret, so they agree.

  This is only true because the dump is logical. If you ever move the database by copying its
  **volume** instead, `PGDATA` carries the old password inside it and the generated secret is
  then wrong — the API cannot log in, and the fix is to make the secret match the old value.

### On the platform stack

Stack 04 needs nothing carried over. Its Vaults are initialized fresh, and
`longhorn_backup_s3_prefix` must stay **different** from the old cluster's, so the two clusters
do not write into the same backup prefix.

---

## 3. Before the window

Everything here is done days ahead, with the old cluster still serving.

1. **Build the new cluster through step 8 of the [README](../README.md).** Stacks 03, 04 and 05,
   both Vaults initialized, unsealed and bootstrapped, and stack 05 applied with the values from
   [§2](#2-what-must-be-identical). Do not create the first admin — the database restore brings
   the real ones.

2. **Point the new cluster's own hostnames somewhere you can reach.** `vtafarm.<domain>` and
   `vtafarm-api.<domain>` still resolve to the old cluster, which is correct for now. Verify the
   new one through the load balancer IP directly, or a `/etc/hosts` entry.

3. **Wait for the wildcard certificate.** cert-manager solves it over DNS-01, so it does not
   depend on DNS pointing at the new cluster:

   ```bash
   kubectl --context <new> -n kube-system get certificate
   ```

   Let's Encrypt allows **5 certificates per week for the same name set**. The old cluster holds
   one for `*.<domain>` and the new one asks for the same name, so do not tear the new cluster
   down and rebuild it repeatedly in one week.

4. **Lower the DNS TTL** on every record in [§4.6](#46-move-dns) to 60 seconds, at least a day
   ahead. The cutover is only as fast as the longest TTL you did not lower.

5. **Run the preflight.** It compares the two clusters and refuses to be satisfied until they
   agree on everything in [§2](#2-what-must-be-identical):

   ```bash
   export SRC_CONTEXT=<old> DST_CONTEXT=<new>
   ./scripts/migrate-cluster.sh preflight
   ```

   It also prints the inventory of what will move. Read it — that list is what you check against
   afterwards.

6. **Take a backup of the old cluster**, so a botched cutover is not also a data loss:

   ```bash
   kubectl --context <old> -n default exec deploy/vtafarm-api-postgresql -- \
     pg_dump -U postgres -d vtafarm -Fc > vtafarm-preflight.dump
   kubectl --context <old> -n vault exec vault-0 -- env VAULT_TOKEN=<root> \
     vault operator raft snapshot save /tmp/vault.snap
   kubectl --context <old> cp vault/vault-0:/tmp/vault.snap ./vault-preflight.snap
   ```

   Both files hold secrets — the dump has passkey material, the snapshot has every master seed.
   Treat them like the `vault-init-*.json` files and delete them once the migration has settled.

---

## 4. The cutover

The farm is down from 4.1 to 4.6. Everything before that is preparation and everything after is
confirmation. Expect **20 to 40 minutes** for a farm the size of the example.

```bash
export SRC_CONTEXT=<old> DST_CONTEXT=<new>
```

### 4.1 Freeze the old cluster

```bash
./scripts/migrate-cluster.sh freeze
```

Scales the API, the frontend and every tenant workload to zero, recording each one's replica
count in an annotation first. PostgreSQL keeps running — the dump is read out of it.

This is the point of no return for consistency, not for data: a VTA's file-backed store is only
safe to copy once nothing is writing to it.

### 4.2 The database

```bash
./scripts/migrate-cluster.sh db
```

Stops the new API, drops and recreates an empty `vtafarm`, and streams `pg_dump` straight into
`pg_restore` — the dump never touches your disk. It compares the row count of `users` on both
sides and starts the new API again.

The API runs its migrations at startup. They no-op: `schema_migrations` came across in the dump.

### 4.3 Vault

Both root tokens are needed — they are different Vaults with different roots. Use the old
cluster's `vault-init-farm.json` and the new one's.

```bash
export SRC_VAULT_TOKEN=<old farm root token>
export DST_VAULT_TOKEN=<new farm root token>
./scripts/migrate-cluster.sh vault
```

Copies three things, over two port-forwards, without writing any of them to disk:

- every secret under `secret/`, which is every VTA's master seed and every component's secrets
- every policy named `vta-user-*`
- every kubernetes-auth role named `vta-user-*`

The policies and roles are copied rather than regenerated because vtafarm-api only creates them
when a session is created. An existing tenant would never get its access back on its own.

Revoke both tokens when you are done:

```bash
vault token revoke -self
```

### 4.4 Tenants

```bash
./scripts/migrate-cluster.sh tenants
```

Per namespace: the namespace itself, the `pod-operator` and `vta` ServiceAccounts, the Role and
RoleBinding, the setup ConfigMaps, the PVCs, then the volume contents, then the Services,
Ingresses and Deployments — and the custom resources an Ingress can depend on: Traefik
Middlewares, IngressRoutes and ServersTransports, plus cert-manager Certificates.

Those last ones do not appear in `kubectl get all`, which is exactly how a first run of this
migration missed a Middleware that one tenant's Ingress pointed at. Traefik refuses to register a
router whose middleware is absent, so that hostname answered 404 with every other object
correctly in place — an application-shaped symptom with an infrastructure cause.

The ServiceAccount names matter more than they look — Vault's per-user kubernetes-auth role is
bound to `vta` in that exact namespace, so a renamed ServiceAccount is a tenant that cannot read
its own seed.

Volume contents move through a `busybox` helper pod on each side, `tar` piped between them, which
preserves ownership. The components run as a fixed non-root user and will not read a tree owned
by anyone else.

### 4.5 Restart the tenants

The Deployments come back at the replica count `freeze` recorded. They will not be healthy yet —
they resolve each other over their public hostnames, which still point at the old cluster.

### 4.6 Move DNS

```bash
./scripts/migrate-cluster.sh dns
```

Prints every hostname the old cluster serves. Change each A record to the new
`cluster_ingress_ip`, in Cloudflare, by hand:

```text
vtafarm.<domain>       A   <new ingress IP>
vtafarm-api.<domain>   A   <new ingress IP>
vta-<name>.<domain>    A   <new ingress IP>     ← one per tenant
mediator-<name>…       A   <new ingress IP>
dids-<name>…           A   <new ingress IP>
vtc-<name>…            A   <new ingress IP>
```

vtafarm-api writes a tenant's record when the session is created and never revisits it, so
existing tenants are edited by hand. Only sessions created **after** the cutover pick up the new
IP automatically, and only because `cluster_ingress_ip` in stack 05 is the new one.

---

## 5. Verify

```bash
./scripts/migrate-cluster.sh verify
```

Then, by hand:

```bash
dig +short vtafarm.<domain>                  # the new ingress IP
curl -sI https://vtafarm-api.<domain>/health # 200, on a certificate that is not the old one
```

- Log in to the frontend with an existing passkey. It proves the database, the JWT path and
  `WEBAUTHN_RP_ID` all came across.
- Open one existing tenant's URL. It proves the tenant's PVC, its Vault seed and its per-user
  Vault role all came across.
- Create one new session end to end. It proves the API's AppRole, the Cloudflare token and
  `cluster_ingress_ip` are right.
- For a `full_stack` tenant, confirm the API can still administer its DID-hosting daemon. That
  is the `did_hosting_did` check from [§2](#2-what-must-be-identical), and it is the failure that
  is expensive to find late.

---

## 6. Rollback

Until DNS moves, rollback is free: nothing on the old cluster was deleted.

```bash
./scripts/migrate-cluster.sh unfreeze
```

Scales the old cluster back to what `freeze` recorded. If DNS has already moved, point it back
first — the two are independent, and the old cluster serves the moment both are true.

After the old cluster has served writes again, the new cluster's copy is stale. Start over from
[§4.1](#41-freeze-the-old-cluster) rather than resuming halfway.

---

## 7. Decommissioning the old cluster

Not for the same day. Leave it frozen but intact for at least a week — long enough for a tenant
nobody logs into daily to be noticed as broken.

When you do retire it, in this order:

1. Confirm the new cluster has a Longhorn backup and an etcd snapshot of its own.
2. Move the old cluster's `vault-init-*.json` files to an archive entry in your password manager,
   labelled dead. Do not delete them until the old volumes are gone.
3. Destroy the old cluster.
4. Delete `vtafarm-preflight.dump` and `vault-preflight.snap`.

---

## 8. Why the Vault is copied rather than restored

The obvious move is `vault operator raft snapshot restore`. It is rejected here on purpose.

A Raft snapshot carries the Vault's barrier keyring, encrypted by whatever seal took it. Both
farm Vaults auto-unseal against their own cluster's transit Vault, and those hold **different**
`autounseal` keys — so the new Vault cannot decrypt the old one's snapshot. Making it work means
transplanting the old transit Vault's storage into the new cluster first, and the result is a new
cluster whose recovery keys, root token and transit key are all secretly the old cluster's. Every
other runbook in this repository would then be describing key material you do not have.

Copying the content instead costs one thing: anything not enumerated is not copied. What the farm
Vault holds is enumerable — the `secret/` KV tree, the `vta-user-*` policies, the `vta-user-*`
kubernetes-auth roles — and `scripts/vault-bootstrap.sh` recreates the rest (mounts, the audit
device, the `vtafarm-api-admin` policy, the AppRole). Leases and tokens are not copied and do not
need to be: every pod re-authenticates.

If you ever do need an exact clone — a Vault whose AppRole `secret_id` must not change, say — the
procedure is: copy `/vault/data` out of `vault-transit-0` on the old cluster into the new one
with both transit pods scaled to zero, unseal the new transit Vault with the **old** cluster's
Shamir keys, re-run `make vault-bootstrap TARGET=transit` with the old root token, initialize the
new farm Vault, then `vault operator raft snapshot restore -force`. Know what you are inheriting
before you do it.

---

## 9. Common problems

| Symptom | Cause |
| --- | --- |
| `preflight` says the target has no app stack | stack 05 has not been applied on the new cluster; it prints the values to carry over first |
| `preflight` flags `DID_HOSTING_DID` | the new cluster generated its own keypair. Put the old one in stack 05's tfvars and re-apply, before the cutover |
| `pg_restore` aborts on a duplicate key | the new database was not empty. Re-run `db` — it drops and recreates before restoring |
| tenant pods `CrashLoopBackOff` after `tenants` | usually the volume, not the workload. Check the copy actually landed: `kubectl exec` into the pod and look at the mount |
| a tenant cannot read its seed | its `vta-user-*` policy or kubernetes-auth role did not copy, or the `vta` ServiceAccount is missing from its namespace |
| `vault` phase: `KV mount 'secret/' is missing` | the new farm Vault was never bootstrapped. `make vault-bootstrap CLUSTER=<new> TARGET=farm` |
| a tenant's URL 404s with `404 page not found` | Traefik has no router for it. Usually a Middleware or other CR the Ingress references that did not come across; `kubectl -n kube-system logs -l app.kubernetes.io/name=rke2-traefik \| grep does.not.exist` names it |
| a tenant's URL 404s with an empty body | the application's own 404. A VTA serves no root path; try a real endpoint before treating it as a fault |
| ACME challenge stuck `pending`, Cloudflare error 9109 | the Cloudflare API token has Client IP Address Filtering and the new cluster's node IPs are not on it. Every node's public IP needs to be, because cert-manager and vtafarm-api egress from whichever node they land on — and `upgrade-os` gives every node a new IP |
| Cloudflare error 526 at the browser | the wildcard certificate has not been issued, so Traefik serves `TRAEFIK DEFAULT CERT` and Cloudflare's Full (strict) rejects it. Fix the issuance; do not leave the zone downgraded to Full |
| a tenant's URL serves the old cluster | that A record was not changed, or its TTL has not expired |
| a new session gets an A record pointing at the old cluster | `cluster_ingress_ip` in stack 05 is still the old IP |
| everyone has to log in again | expected — the JWT secret changed. See [§2](#two-values-you-may-let-change) |

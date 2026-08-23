# Remote state

OpenTofu state lives in the same Hetzner Object Storage bucket that already receives the etcd
snapshots and the Rancher backups. Every stack locks that state while it runs, so two people
cannot apply at the same time, and nobody is the single machine that holds the cluster together.

This document is the whole story: how the bucket is laid out, what a second operator needs, and
how to migrate a checkout that still keeps its state on disk.

## Contents

- [What lives where](#what-lives-where)
- [How the backend is configured](#how-the-backend-is-configured)
- [How locking works](#how-locking-works)
- [One-time setup](#one-time-setup)
- [Migrating existing local state](#migrating-existing-local-state)
- [Onboarding a second operator](#onboarding-a-second-operator)
- [Changing a tfvars value](#changing-a-tfvars-value)
- [When a lock is stuck](#when-a-lock-is-stuck)
- [Recovering a bad state](#recovering-a-bad-state)
- [What this does not protect](#what-this-does-not-protect)

---

## What lives where

Three things must reach a second operator, and each takes a different route:

| | Route | Why |
| --- | --- | --- |
| Configuration (`*.tf`, modules, scripts) | Git | No secrets, and it must be reviewable |
| State | The bucket, `$TF_PREFIX/tfstate` | Written by OpenTofu, locked while in use |
| `terraform.tfvars` | The bucket, `$TF_PREFIX/tfvars` | Site-specific and secret, so never in Git |
| `.env` | Password manager, by hand | It holds the key to the bucket, so it cannot come from the bucket |

`.env` is the only thing handed over out of band. Everything else follows from it.

`TF_PREFIX` in `.env` names the folder that holds all of it. With the default it looks like
this:

```text
<your-bucket>/                              versioning on, non-current kept 30 days
├── <k3s cluster name>/                     etcd snapshots, written by k3s
├── rancher-backup/                         Rancher backups, written by rancher-backup
└── opentofu/                            TF_PREFIX
    ├── tfstate/
    │   ├── 01-infra/terraform.tfstate
    │   ├── 02-rancher/terraform.tfstate
    │   ├── 03-rke2-clusters/<cluster>/terraform.tfstate
    │   ├── 04-vtafarm-platform/<cluster>/terraform.tfstate
    │   └── 05-vtafarm-app/<cluster>/terraform.tfstate
    └── tfvars/
        ├── 01-infra/terraform.tfvars
        ├── 02-rancher/terraform.tfvars
        └── 0{3,4,5}-*/<cluster>/terraform.tfvars
```

Pick `TF_PREFIX` before you migrate. Changing it afterwards makes OpenTofu look for state that
is not there and offer to create everything from scratch; you would have to copy the objects
across first.

Two files are deliberately **not** synced:

- `kubeconfig.yaml` — regenerate it with `make kubeconfig-rke2 CLUSTER=<name>`
- `vault-init-*.json` — Vault recovery keys and root tokens. Password manager only, never a
  bucket. See [vault.md](vault.md).

---

## How the backend is configured

Each stack has a `backend.tf` that is tracked in Git and carries no site-specific value:

```hcl
terraform {
  backend "s3" {
    use_path_style = true
    use_lockfile   = true

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
  }
}
```

Every stack's copy is identical. The bucket, the region and the key are supplied at init time,
which is why every init goes through `make` rather than a bare `tofu init`:

```makefile
backend_config = -backend-config="bucket=$(TF_STATE_BUCKET)" \
                 -backend-config="region=$(AWS_REGION)" \
                 -backend-config="key=$(TF_PREFIX)/tfstate/$(1)/terraform.tfstate"
```

`$(1)` is the stack's path — `01-infra`, or `03-rke2-clusters/<cluster>` for the three stacks
that keep one root per cluster. The endpoint and the credentials come from the environment:
`AWS_ENDPOINT_URL_S3`, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. The Makefile loads all
of it from `.env`.

Keeping every site value out of `backend.tf` is what lets this repository be cloned and pointed
at a different Hetzner project, with different prefixes, without editing a tracked file. The
cost is that a bare `tofu init` has no key and will prompt for one — answering it wrongly points
a stack at another stack's state. Use the `make` targets.

The four `skip_*` settings turn off the parts of the AWS provider that only exist on AWS.
`use_path_style` is required because Hetzner addresses buckets as `endpoint/bucket`, not
`bucket.endpoint`.

---

## How locking works

`use_lockfile = true` makes OpenTofu take the lock in the bucket itself. Before it touches
state it writes `<key>.tflock` with an `If-None-Match: *` header, which S3 honours only when
the object does not already exist. A second run gets `412 PreconditionFailed` back and refuses
to start:

```text
Error: Error acquiring the state lock
Error message: operation error S3: PutObject, api error PreconditionFailed
```

Hetzner Object Storage implements the conditional write, so there is nothing else to set up —
no DynamoDB table and no lock server. The lock is released at the end of the run.

Locking is not the same as the bucket's Object Lock feature, which is for write-once retention
and must stay **disabled**: it would stop OpenTofu from ever updating a state file.

---

## One-time setup

Do this once per bucket, before the first migration.

```bash
cp .env.example .env
```

Fill in the bucket name, the region, the endpoint and the S3 credential pair. `.env` is
gitignored. Then:

```bash
make state-bucket-setup
```

That enables versioning, so a state file can be rolled back, and installs a lifecycle rule
that expires non-current versions after 30 days.

The lifecycle rule is not optional. The etcd snapshots share this bucket, and k3s prunes them
by deleting objects. Under versioning a delete only hides an object, so without the rule every
pruned snapshot would sit in the bucket forever. Thirty days bounds that, and still gives state
a month of history. Override it with `NONCURRENT_DAYS=… make state-bucket-setup`.

---

## Migrating existing local state

Only needed for a checkout that predates this change and still has `terraform.tfstate` files on
disk. Do the stacks one at a time and verify each before moving on.

1. Back up first. These files hold the k3s token, the Rancher password, the JWT secret and the
   database password, so treat the archive as a secret:

   ```bash
   tar czf ~/vtafarm-state-backup-$(date +%F).tar.gz $(find stacks -name 'terraform.tfstate*')
   ```

2. Upload the tfvars, so the bucket is complete before state moves:

   ```bash
   make tfvars-push
   ```

3. Migrate stack 01, then verify. Each `migrate-state` target prompts once — `tofu` has
   noticed the backend changed and is offering to copy the existing state up. Answer `yes`:

   ```bash
   make migrate-state
   make plan
   ```

   `make plan` must report no changes. If it wants to create everything, the state did not come
   across: stop, and see the warning below.

4. Do the rest one at a time, verifying between each. Stacks 03 to 05 take the cluster name:

   | Stack | Migrate | Verify |
   | --- | --- | --- |
   | 02 | `make migrate-state-rancher` | `make plan-rancher` |
   | 03 | `make migrate-state-rke2 CLUSTER=<name>` | `make plan-rke2 CLUSTER=<name>` |
   | 04 | `make migrate-state-vtafarm-platform CLUSTER=<name>` | `make plan-vtafarm-platform CLUSTER=<name>` |
   | 05 | `make migrate-state-vtafarm-app CLUSTER=<name>` | `make plan-vtafarm-app CLUSTER=<name>` |

   These targets exist because plain `init` refuses to run once `backend.tf` appears until it is
   told what to do with the old state. They are ordinary inits with `-migrate-state` added, and
   they derive the key exactly as `make init` does, so the two cannot drift apart.

   > At the prompt, `yes` copies your state up. **Never answer the `-reconfigure` suggestion**
   > if `tofu` offers one — that starts from an empty state, and the next apply would try to
   > rebuild infrastructure that already exists. Your local `terraform.tfstate` is untouched
   > until step 6, so a wrong answer is recoverable: re-run the migrate target.

5. Confirm every state file arrived:

   ```bash
   set -a && . ./.env && set +a
   aws --endpoint-url "$AWS_ENDPOINT_URL_S3" s3 ls --recursive \
     "s3://$TF_STATE_BUCKET/$TF_PREFIX/tfstate/"
   ```

6. Remove the local copies, so nobody can apply from a stale file by accident. The
   `-not -path` is load-bearing: each stack's `.terraform/terraform.tfstate` has the same
   filename but is the backend configuration cache, and deleting it makes every later command
   fail with `Backend initialization required` until you re-run the init targets:

   ```bash
   find stacks -not -path '*/.terraform/*' \
     \( -name 'terraform.tfstate' -o -name 'terraform.tfstate.backup' \) -delete
   ```

---

## Onboarding a second operator

Give them `.env` through the password manager. Nothing else is handed over by hand.

```bash
git clone <repo> && cd vtafarm-k8s
cp .env.example .env
```

Paste the values they were given into that `.env`. Stacks 01 and 02 are tracked, so they need
nothing further beyond their tfvars and an init:

```bash
make tfvars-pull
make init
make plan
```

`make plan` must report no changes.

Stacks 03 to 05 keep one directory per cluster, and those directories are gitignored — they are
generated from `_template`, not shared. Scaffold them **before** pulling, because `tfvars-pull`
skips a cluster whose directory does not exist and the scaffold refuses to overwrite one that
does:

```bash
make new-rke2-cluster     CLUSTER=rke2-vtafarm-production
make new-vtafarm-platform CLUSTER=rke2-vtafarm-production
make new-vtafarm-app      CLUSTER=rke2-vtafarm-production

make tfvars-pull

make init-rke2 CLUSTER=rke2-vtafarm-production
make plan-rke2 CLUSTER=rke2-vtafarm-production
```

The `tfvars-pull` in the middle is what replaces the placeholder `terraform.tfvars` each
scaffold wrote with the real one from the bucket.

The scaffold copies `backend.tf` unchanged — it holds no cluster name. `make init-rke2` is what
supplies the key, derived from `CLUSTER`.

Finally, the kubeconfigs, which stacks 04 and 05 read from the cluster directory:

```bash
make kubeconfig-rke2 CLUSTER=rke2-vtafarm-production
```

---

## Changing a tfvars value

`terraform.tfvars` is edited locally and pushed. There is no decryption step: what comes down
is what `tofu` reads.

```bash
make tfvars-diff
vim stacks/01-infra/terraform.tfvars
make tfvars-push
```

`tfvars-diff` names the variables that differ and never prints their values, so it is safe to
run anywhere. `tfvars-push` shows that same report and asks before it uploads.

Push last-write-wins, so tell the other operators when you change something. Versioning is the
net underneath that: the previous copy stays recoverable for 30 days.

`tfvars-pull` overwrites local tfvars without asking. Run `make tfvars-diff` first if you are not
sure whether you have unpushed edits.

---

## When a lock is stuck

A run that is killed mid-flight — `Ctrl-C` twice, a laptop that sleeps, a dropped connection —
leaves `<key>.tflock` behind. Every later run then fails with `Error acquiring the state lock`.

**Check that nobody is actually applying first.** The error prints the lock's `ID`, `Who` and
`Created` fields; `Who` is the user and host that took it. If that is a colleague mid-apply,
wait. Breaking a live lock is how state gets corrupted.

Once you are sure it is stale, unlock with the `ID` from the error message:

```bash
tofu -chdir=stacks/01-infra force-unlock <ID>
```

If even that fails, delete the object directly:

```bash
aws --endpoint-url "$AWS_ENDPOINT_URL_S3" s3 rm \
  "s3://$TF_STATE_BUCKET/$TF_PREFIX/tfstate/01-infra/terraform.tfstate.tflock"
```

---

## Recovering a bad state

Versioning keeps every previous copy for 30 days. List them, then download the one you want:

```bash
aws --endpoint-url "$AWS_ENDPOINT_URL_S3" s3api list-object-versions \
  --bucket "$TF_STATE_BUCKET" --prefix "$TF_PREFIX/tfstate/01-infra/terraform.tfstate"

aws --endpoint-url "$AWS_ENDPOINT_URL_S3" s3api get-object \
  --bucket "$TF_STATE_BUCKET" --key "$TF_PREFIX/tfstate/01-infra/terraform.tfstate" \
  --version-id <VersionId> ./recovered.tfstate
```

Inspect it before you put it back — `tofu show -json ./recovered.tfstate` — then:

```bash
tofu -chdir=stacks/01-infra state push ./recovered.tfstate
```

`state push` takes the lock like any other write, so it is safe against a concurrent run.

---

## What this does not protect

**State is not encrypted.** It holds the k3s join token, the Rancher bootstrap password, the
RKE2 kubeconfig, the vtafarm JWT secret and the database password, and it sits in the bucket in
the clear. So do the etcd snapshots, which contain every Kubernetes Secret in the management
cluster. Anyone holding the S3 credential holds the farm — treat that credential the way you
treat a root password.

OpenTofu can encrypt state client-side with an `encryption` block. Adding it is its own
migration and it is not done here.

**Hetzner S3 credentials cannot be scoped.** They are project-wide: there is no way to issue a
key that reaches only this bucket, or only the `tofu/` prefix. A second credential pair would
buy no isolation, which is why everyone uses the same one and why revoking access means
rotating it for everybody.

**Locking is per state file, not per farm.** Two people can apply stack 03 and stack 04 of the
same cluster at the same moment without either lock noticing. The stack order in the
[README](../README.md) is still something people, not tooling, have to respect.

# Remote state

OpenTofu state lives in the same Hetzner Object Storage bucket that already receives the etcd
snapshots and the Rancher backups. Every stack locks that state while it runs, so two people
cannot apply at the same time, and nobody is the single machine that holds the cluster together.

This document is the whole story: how the bucket is laid out, what a second operator needs, and
what to do when a lock or a state file goes wrong.

## Contents

- [What lives where](#what-lives-where)
- [How the backend is configured](#how-the-backend-is-configured)
- [How locking works](#how-locking-works)
- [One-time setup](#one-time-setup)
- [Onboarding a second operator](#onboarding-a-second-operator)
- [Changing a tfvars value](#changing-a-tfvars-value)
- [When a lock is stuck](#when-a-lock-is-stuck)
- [Recovering a bad state](#recovering-a-bad-state)
- [What this does not protect](#what-this-does-not-protect)

---

## What lives where

What a second operator needs arrives by one of three routes:

| | Route | Why |
| --- | --- | --- |
| Configuration (`*.tf`, modules, scripts) | Git | No secrets, and it must be reviewable |
| State | The bucket, `$TF_PREFIX/tfstate` | Written by OpenTofu, locked while in use |
| `terraform.tfvars` | The bucket, `$TF_PREFIX/tfvars` | Site-specific and secret, so never in Git |
| `.env` | Password manager, by hand | It holds the key to the bucket, so it cannot come from the bucket |
| The SSH key pair | Password manager, by hand | The nodes only accept the key that was uploaded when they were created |

Those last two are the only things handed over out of band; everything else follows from them.
`TF_PREFIX` names the folder holding both trees, one key per stack:

```text
<your-bucket>/                              versioning on, non-current kept 30 days
├── <k3s cluster name>/                     etcd snapshots, written by k3s
├── rancher-backup/                         Rancher backups, written by rancher-backup
└── opentofu/                               TF_PREFIX
    ├── tfstate/
    │   ├── 01-infra/terraform.tfstate
    │   ├── 02-rancher/terraform.tfstate
    │   └── 0{3,4,5}-*/<cluster>/terraform.tfstate
    └── tfvars/                              same layout, terraform.tfvars
```

Pick `TF_PREFIX` before the first init. Changing it afterwards makes OpenTofu look for state
that is not there and offer to create everything from scratch; you would have to copy the
objects across first.

Two files are deliberately **not** synced:

- `kubeconfig.yaml` — regenerate it with `make kubeconfig` for the management cluster, or
  `make kubeconfig-rke2 CLUSTER=<name>` for a downstream one
- `vault-init-*.json` — Vault recovery keys and root tokens. Password manager only, never a
  bucket. See [vault.md](vault.md).

---

## How the backend is configured

Every stack's `backend.tf` is identical and carries no site value. The bucket, the region and
the key arrive at init time from `-backend-config`, which the Makefile builds out of `.env`:

```makefile
key=$(TF_PREFIX)/tfstate/$(1)/terraform.tfstate
```

`$(1)` is the stack's path — `01-infra`, or `03-rke2-clusters/<cluster>` for the three stacks
that keep one root per cluster. That indirection is what lets this repository be cloned and
pointed at a different Hetzner project without editing a tracked file. The cost is that a bare
`tofu init` has no key and will prompt for one, and a wrong answer points a stack at another
stack's state. Use the `make` targets.

`use_path_style` is required because Hetzner addresses buckets as `endpoint/bucket`, not
`bucket.endpoint`. The four `skip_*` settings turn off provider checks that only exist on AWS.

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

Do this once per bucket, before the first init.

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

## Onboarding a second operator

Give them `.env` and the SSH key pair through the password manager. Nothing else is handed
over by hand.

```bash
git clone <repo> && cd vtafarm-k8s
cp .env.example .env
```

Paste the values into that `.env`. The SSH key pair goes in `~/.ssh/`, under the filename
`ssh_private_key_path` names in `stacks/01-infra/terraform.tfvars`:

```bash
mv <key> <key>.pub ~/.ssh/
chmod 600 ~/.ssh/<key>
```

Generate the cluster scaffolds:

```bash
make new-rke2-cluster     CLUSTER=rke2-vtafarm-production
make new-vtafarm-platform CLUSTER=rke2-vtafarm-production
make new-vtafarm-app      CLUSTER=rke2-vtafarm-production
```

Then initialize every stack. `tofu init` reads no `terraform.tfvars` — the bucket, the region and
the key all arrive from `.env` — so the whole init pass comes before the pull:

```bash
make init
make init-rke2             CLUSTER=rke2-vtafarm-production
make kubeconfig-rke2       CLUSTER=rke2-vtafarm-production
make init-vtafarm-platform CLUSTER=rke2-vtafarm-production
make init-vtafarm-app      CLUSTER=rke2-vtafarm-production
```

Every directory now exists, so one pull fills them all, replacing the placeholder
`terraform.tfvars` each scaffold wrote with the real one from the bucket:

```bash
make tfvars-pull
```

Then plan. Each of these must report no changes:

```bash
make plan
make plan-rancher
make plan-rke2             CLUSTER=rke2-vtafarm-production
make plan-vtafarm-platform CLUSTER=rke2-vtafarm-production
make plan-vtafarm-app      CLUSTER=rke2-vtafarm-production
```

Stacks 04 and 05 have their kubeconfig already — `make kubeconfig-rke2` wrote it during the init
pass. Two more targets fetch the management cluster's and put both in `~/.kube/config`, so
`kubectl` can reach either one:

```bash
make kubeconfig
make kubeconfig-merge
make kubeconfig-merge-rke2 CLUSTER=rke2-vtafarm-production
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

Versioning keeps every previous copy for 30 days. List them:

```bash
make state-versions STACK=01-infra
make state-versions STACK=03-rke2-clusters CLUSTER=rke2-vtafarm-production
```

`STACK` is the path below `$TF_PREFIX/tfstate`, and stacks 03 to 05 take `CLUSTER` as well. The
row marked `LATEST` is the state in use now. Push an older one back with its version id:

```bash
make state-restore STACK=01-infra VERSION=<VERSION_ID>
```

That downloads the version, prints the serial, the lineage and the resource count of both it and
the state currently in the bucket, and asks before it writes. It refuses to run without a
terminal to ask in.

The push is `tofu state push -force`. Restoring rewinds the serial, and without `-force` OpenTofu
declines to move a state backwards. `-force` is not a lock override: the push takes the lock like
any other write, so it is still safe against a concurrent run.

A restored state is a claim about the world, not the world itself. Plan the stack afterwards and
read the result before you apply anything.

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

# A short introduction to OpenTofu

**The main idea:** you *describe the end state you want* in `.tf` files. OpenTofu compares that
description with what already exists in the cloud, and then works out what to change. It is not
a script. There is no execution order. OpenTofu builds a dependency graph from the way your
resources refer to each other.

**Four kinds of file:**

| File | Role |
| --- | --- |
| `variables.tf` | Declares which settings exist, like the parameters of a function |
| `terraform.tfvars` | The values you supply (**contains secrets, and Git ignores it**) |
| other `*.tf` | The resource definitions |
| `terraform.tfstate` | The record of everything OpenTofu created. **If you lose it, OpenTofu forgets everything and wants to build it all again** |

**Four commands:**

```bash
tofu init      # download providers (first run, or after you change provider versions)
tofu plan      # show what would happen. It changes nothing, so run it as often as you like
tofu apply     # do it. It shows the plan first and asks you to type yes
tofu destroy   # delete everything this stack created
```

**How to read a plan:**

```text
+ create      a new resource
~ update      changed in place, with no impact on the service
-/+ replace   destroyed and created again  ←←← stop and read carefully
- destroy     removed
```

> ⚠️ The dangerous line is `-/+ replace` on `hcloud_server.server`. It means OpenTofu wants to
> rebuild control-plane nodes, and rebuilding all three at once destroys the cluster. This repo
> prevents the most common cause with `lifecycle { ignore_changes = [user_data, ssh_keys,
> image] }`. Cloud-init runs only at the first boot, so editing it changes nothing on a running
> node, but it would still trigger a rebuild. When you really want to rebuild a node, do it
> **one node at a time**:
> `tofu apply -replace='hcloud_server.server[2]'`

**Where is the state?**
On your machine, in `stacks/*/terraform.tfstate`. This is fine for a single operator, but you
must **back it up**, or move it to a remote backend such as S3-compatible object storage. If
you lose the state file, recovery is slow and difficult.

> The `terraform.` prefixes are not a mistake. OpenTofu still reads `terraform.tfvars`, writes
> `terraform.tfstate`, and stores its plugin cache in `.terraform/`.

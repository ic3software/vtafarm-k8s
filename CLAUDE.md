# CLAUDE.md

OpenTofu for live Hetzner infrastructure (HA k3s + Rancher + downstream RKE2). See `README.md`
for architecture. A careless change costs money or downs a production cluster.

## Branch

Never work on `main`. Only when the current branch is `main` do you create one, before the
first edit of any task: `git checkout -b <type>/<kebab-desc>` (`feat/`, `fix/`, `chore/`,
`docs/`) and say the name. On any other branch, stay there — even if the task looks unrelated
to what the branch is named. Ask before branching if you think a split is warranted.

## Commit

- Never commit or push unless told to, each time. Always `--signoff`.
- One logical commit per task, conventional-commit subject.
- Never stage `*.tfvars`, `*.tfstate*`, `kubeconfig*`, `*.pem`. New variables go in
  `terraform.tfvars.example`.

## Change

- Minimal diff, scoped to the request. No unrelated refactors, renames or reformatting.
- Comment only non-obvious reasoning: a constraint, an invariant, a k3s/Rancher/Hetzner quirk.
  Never narrate what the code does.
- Version pins are coupled (k3s v1.35.7 ↔ Rancher 2.14.3). Do not bump unless that is the task.
- Markdown prose wraps at 100 columns.

## Finish

Run `make fmt` then `make lint` (fmt, validate, `tofu test`, markdownlint) — that is the
whole verification story here; `make init` first in a fresh checkout. Then read `git diff` and
delete anything unearned: debug leftovers, narrating comments, stray files, single-caller
abstractions. If a check fails or was skipped, say so with the output.

## Never run unprompted

`tofu apply`/`destroy` and the make targets wrapping them, including `kubeconfig`
(`-replace -auto-approve`) and `upgrade-os`; writing `kubectl`/`helm` verbs; mutating `scripts/`.
Propose the command instead. Read-only (`plan`, `output`, `make status`, `kubectl get`) is fine.

## Secrets

State, `terraform.tfvars`, `kubeconfig`, `output -raw` (k3s token, Rancher password) hold live
credentials. Never echo them into the transcript, a file, or a commit message.

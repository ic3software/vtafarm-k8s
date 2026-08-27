#!/usr/bin/env bash
#
# Lists the versions the bucket keeps of one stack's state, and pushes one of
# them back. Versioning is what makes this possible; scripts/state-bucket-setup.sh
# turns it on and bounds how long the copies live. See docs/remote-state.md.
#
# Usage: state-restore.sh list    <stack path below $TF_PREFIX/tfstate>
#        state-restore.sh restore <stack path> <version-id>
set -euo pipefail

MODE="${1:-}"
case "$MODE" in
list | restore) ;;
*)
  echo "usage: $0 <list|restore> <stack path> [version-id]" >&2
  exit 2
  ;;
esac

STACK="${2:-}"
[ -n "$STACK" ] || {
  echo "set STACK - for example: make state-versions STACK=01-infra" >&2
  exit 2
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${TF_STATE_BUCKET:?set TF_STATE_BUCKET - copy .env.example to .env}"
: "${AWS_ENDPOINT_URL_S3:?set AWS_ENDPOINT_URL_S3 - copy .env.example to .env}"

command -v jq >/dev/null 2>&1 || {
  echo "==> ERROR: jq not found in PATH" >&2
  exit 1
}

KEY="${TF_PREFIX:-opentofu}/tfstate/${STACK}/terraform.tfstate"
S3API=(aws --endpoint-url "$AWS_ENDPOINT_URL_S3" s3api)

# The stack path is both the key below the tfstate prefix and, through this
# mapping, the directory `tofu state push` has to run in.
stack_dir() {
  case "$1" in
  01-infra | 02-rancher) printf 'stacks/%s\n' "$1" ;;
  03-rke2-clusters/?* | 04-vtafarm-platform/?* | 05-vtafarm-app/?*)
    printf 'stacks/%s/clusters/%s\n' "${1%%/*}" "${1#*/}"
    ;;
  *) return 1 ;;
  esac
}

DIR="$(stack_dir "$STACK")" || {
  cat >&2 <<USAGE
no stack owns "${STACK}". Use one of:
  STACK=01-infra
  STACK=02-rancher
  STACK=03-rke2-clusters    CLUSTER=<name>
  STACK=04-vtafarm-platform CLUSTER=<name>
  STACK=05-vtafarm-app      CLUSTER=<name>
USAGE
  exit 2
}

# --prefix also matches terraform.tfstate.tflock, so the key has to be filtered
# exactly or a stale lock shows up as a version of the state.
list_versions() {
  "${S3API[@]}" list-object-versions \
    --bucket "$TF_STATE_BUCKET" --prefix "$KEY" \
    --query "Versions[?Key=='${KEY}'].[LastModified,VersionId,Size,IsLatest]" \
    --output text
}

describe() {
  jq -r '"serial \(.serial), lineage \(.lineage), \([.resources[]?.instances[]?] | length) resource instances"' "$1"
}

case "$MODE" in
list)
  echo "==> versions of ${KEY}"
  versions="$(list_versions)"
  if [ -z "$versions" ]; then
    echo "  none - no state at that key, or versioning was off when it was written"
    exit 0
  fi
  { printf 'LAST_MODIFIED\tVERSION_ID\tBYTES\tLATEST\n'; printf '%s\n' "$versions"; } |
    column -t -s $'\t' | sed 's/^/  /'
  echo
  echo "  roll back with: make state-restore STACK=… VERSION=<VERSION_ID>"
  ;;

restore)
  VERSION="${3:-}"
  [ -n "$VERSION" ] || {
    echo "set VERSION - list them with: make state-versions" >&2
    exit 2
  }

  SCRATCH_DIR="$(mktemp -d)"
  trap 'rm -rf "$SCRATCH_DIR"' EXIT
  RECOVERED="${SCRATCH_DIR}/recovered.tfstate"
  CURRENT="${SCRATCH_DIR}/current.tfstate"

  meta="$("${S3API[@]}" get-object \
    --bucket "$TF_STATE_BUCKET" --key "$KEY" --version-id "$VERSION" "$RECOVERED")"
  jq -e '.lineage and .serial' "$RECOVERED" >/dev/null 2>&1 || {
    echo "==> ERROR: version ${VERSION} is not an OpenTofu state file" >&2
    exit 1
  }

  if ! tofu -chdir="${REPO_ROOT}/${DIR}" state pull >"$CURRENT" 2>"${SCRATCH_DIR}/err"; then
    echo "==> ERROR: could not read the current state of ${DIR}" >&2
    sed 's/^/  /' "${SCRATCH_DIR}/err" >&2
    exit 1
  fi

  echo "==> ${DIR}"
  echo "  in the bucket now: $(describe "$CURRENT")"
  echo "  restoring:         $(describe "$RECOVERED")"
  echo "  written:           $(jq -r '.LastModified' <<<"$meta")"
  if [ "$(jq -r '.lineage' "$CURRENT")" != "$(jq -r '.lineage' "$RECOVERED")" ]; then
    echo "  WARNING: different lineage - this copy was written before the state was recreated"
  fi

  # State is overwritten in place and the copy it replaces is only recoverable
  # for as long as the retention rule keeps it, so this one refuses to run
  # unattended rather than assuming consent the way tfvars-push does.
  [ -t 0 ] || {
    echo "==> ERROR: run this from a terminal - it asks before overwriting" >&2
    exit 1
  }
  read -r -p "push this over the current state? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }

  # A restored copy carries the serial it had when it was written, which is
  # behind what is in the bucket now; -force is what lets state move backwards.
  # It does not skip the lock: the push takes it like any other write.
  tofu -chdir="${REPO_ROOT}/${DIR}" state push -force "$RECOVERED"
  echo "==> restored. Plan this stack before you apply anything."
  ;;
esac

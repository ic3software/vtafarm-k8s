#!/usr/bin/env bash
# Moves terraform.tfvars between this checkout and the tfvars prefix of the
# state bucket. Git tracks only the .example files, so the bucket is what a
# second operator pulls the real values from. See docs/remote-state.md.
set -euo pipefail

MODE="${1:-}"
case "$MODE" in
push | pull | diff) ;;
*)
  echo "usage: $0 <push|pull|diff>" >&2
  exit 2
  ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${TF_STATE_BUCKET:?set TF_STATE_BUCKET - copy .env.example to .env}"
: "${AWS_ENDPOINT_URL_S3:?set AWS_ENDPOINT_URL_S3 - copy .env.example to .env}"

TFVARS_PREFIX="${TF_PREFIX:-opentofu}/tfvars"
PREFIX="s3://${TF_STATE_BUCKET}/${TFVARS_PREFIX}"
S3=(aws --endpoint-url "$AWS_ENDPOINT_URL_S3" s3)

FIXED_STACKS=(01-infra 02-rancher)
CLUSTER_STACKS=(03-rke2-clusters 04-vtafarm-platform 05-vtafarm-app)

# "<path relative to the repo root><tab><key below the tfvars prefix>" for every
# tfvars that exists locally.
local_pairs() {
  local stack cluster_dir cluster
  for stack in "${FIXED_STACKS[@]}"; do
    if [ -f "${REPO_ROOT}/stacks/${stack}/terraform.tfvars" ]; then
      printf '%s\t%s\n' "stacks/${stack}/terraform.tfvars" "${stack}/terraform.tfvars"
    fi
  done
  for stack in "${CLUSTER_STACKS[@]}"; do
    for cluster_dir in "${REPO_ROOT}/stacks/${stack}/clusters"/*/; do
      [ -d "$cluster_dir" ] || continue
      cluster="$(basename "$cluster_dir")"
      if [ -f "${cluster_dir}terraform.tfvars" ]; then
        printf '%s\t%s\n' \
          "stacks/${stack}/clusters/${cluster}/terraform.tfvars" \
          "${stack}/${cluster}/terraform.tfvars"
      fi
    done
  done
}

remote_keys() {
  "${S3[@]}" ls --recursive "${PREFIX}/" 2>/dev/null |
    awk '{print $4}' |
    sed -n "s|^${TFVARS_PREFIX}/||p"
}

local_path_for_key() {
  local stack="${1%%/*}" rest="${1#*/}"
  case "$stack" in
  01-infra | 02-rancher) printf 'stacks/%s/%s\n' "$stack" "$rest" ;;
  03-rke2-clusters | 04-vtafarm-platform | 05-vtafarm-app)
    printf 'stacks/%s/clusters/%s\n' "$stack" "$rest"
    ;;
  *) return 1 ;;
  esac
}

# tfvars hold tokens and private keys, so a report names the variables that
# differ and never their values.
changed_variables() {
  diff <(sort "$1") <(sort "$2") |
    sed -n 's/^[<>][[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*/\1/p' |
    sort -u | paste -sd', ' -
}

# Prints one status line per file and returns 0 when at least one differs.
report() {
  local direction="$1" path key names found=1
  local scratch="${SCRATCH_DIR}/remote"

  while IFS=$'\t' read -r path key; do
    if ! "${S3[@]}" cp "${PREFIX}/${key}" "$scratch" --only-show-errors 2>/dev/null; then
      echo "  ${path}: not in the bucket yet"
      found=0
      continue
    fi
    names="$(changed_variables "$scratch" "${REPO_ROOT}/${path}")"
    if [ -z "$names" ]; then
      echo "  ${path}: same"
    else
      echo "  ${path}: ${direction} ${names}"
      found=0
    fi
  done < <(local_pairs)

  return "$found"
}

SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

case "$MODE" in
diff)
  echo "==> local vs ${PREFIX}"
  report "differs in" || echo "  (nothing to push)"
  ;;

push)
  echo "==> about to overwrite ${PREFIX}"
  if ! report "would change"; then
    echo "  nothing to push"
    exit 0
  fi
  if [ -t 0 ]; then
    read -r -p "push these? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }
  fi
  while IFS=$'\t' read -r path key; do
    "${S3[@]}" cp "${REPO_ROOT}/${path}" "${PREFIX}/${key}" --only-show-errors
    echo "  pushed ${path}"
  done < <(local_pairs)
  ;;

pull)
  pulled=0
  while read -r key; do
    [ -n "$key" ] || continue
    if ! path="$(local_path_for_key "$key")"; then
      echo "  skipped ${TFVARS_PREFIX}/${key}: no stack owns this prefix"
      continue
    fi
    # A cluster root is scaffolded, not synced, so its tfvars has nowhere to go
    # until the directory exists. Writing one would also block the scaffold,
    # which refuses to touch an existing path.
    if [ ! -d "${REPO_ROOT}/$(dirname "$path")" ]; then
      echo "  skipped ${path}: scaffold the cluster first"
      continue
    fi
    "${S3[@]}" cp "${PREFIX}/${key}" "${REPO_ROOT}/${path}" --only-show-errors
    echo "  pulled ${path}"
    pulled=$((pulled + 1))
  done < <(remote_keys)
  if [ "$pulled" -eq 0 ]; then
    echo "  nothing pulled - is ${PREFIX}/ empty?"
  fi
  ;;
esac

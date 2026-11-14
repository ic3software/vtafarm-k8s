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
CLUSTER_STACKS=(03-rke2-clusters 04-vtafarm-platform 05-vtafarm-app 06-vtafarm-observability)

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

# `aws s3 ls` exits non-zero for an empty prefix and for a real failure alike;
# only stderr tells them apart.
remote_keys() {
  local out="${SCRATCH_DIR}/listing" err="${SCRATCH_DIR}/listing-err"
  if ! "${S3[@]}" ls --recursive "${PREFIX}/" >"$out" 2>"$err" && [ -s "$err" ]; then
    echo "could not list ${PREFIX}/" >&2
    sed 's/^/  /' "$err" >&2
    return 1
  fi
  awk '{print $4}' "$out" | sed -n "s|^${TFVARS_PREFIX}/||p"
}

local_path_for_key() {
  local stack="${1%%/*}" rest="${1#*/}"
  case "$stack" in
  01-infra | 02-rancher) printf 'stacks/%s/%s\n' "$stack" "$rest" ;;
  03-rke2-clusters | 04-vtafarm-platform | 05-vtafarm-app | 06-vtafarm-observability)
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
    sort -u | paste -sd, - | sed 's/,/, /g'
}

# Variable order does not matter, but every other content change does. Checking
# this separately from changed_variables prevents a heredoc-only edit from
# being mistaken for an unchanged file.
files_match() {
  cmp -s <(sort "$1") <(sort "$2")
}

change_description() {
  local names
  names="$(changed_variables "$1" "$2")"
  if [ -n "$names" ]; then
    printf '%s\n' "$names"
  else
    printf 'file content\n'
  fi
}

# Prints the local-to-remote status and records only files that need uploading.
plan_push() {
  local direction="$1" keys="$2" plan="$3"
  local path key description remote_file
  : >"$plan"

  while IFS=$'\t' read -r path key; do
    if ! grep -qxF "$key" <<<"$keys"; then
      echo "  ${path}: not in the bucket yet"
      printf '%s\t%s\n' "$path" "$key" >>"$plan"
      continue
    fi
    # Catch download failures explicitly so they cannot be read as a file full
    # of differences.
    remote_file="${SCRATCH_DIR}/remote"
    if ! "${S3[@]}" cp "${PREFIX}/${key}" "$remote_file" --only-show-errors; then
      echo "could not download ${TFVARS_PREFIX}/${key}" >&2
      exit 1
    fi
    if files_match "$remote_file" "${REPO_ROOT}/${path}"; then
      echo "  ${path}: same"
    else
      description="$(change_description "$remote_file" "${REPO_ROOT}/${path}")"
      echo "  ${path}: ${direction} ${description}"
      printf '%s\t%s\n' "$path" "$key" >>"$plan"
    fi
  done < <(local_pairs)
}

# Prints the remote-to-local status, caches changed remote files, and records
# only files that need to be written locally.
plan_pull() {
  local keys="$1" plan="$2"
  local key path description remote_file index=0 eligible=0
  : >"$plan"

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

    eligible=$((eligible + 1))
    index=$((index + 1))
    remote_file="${SCRATCH_DIR}/pull-${index}"
    if ! "${S3[@]}" cp "${PREFIX}/${key}" "$remote_file" --only-show-errors; then
      echo "could not download ${TFVARS_PREFIX}/${key}" >&2
      exit 1
    fi
    if [ ! -f "${REPO_ROOT}/${path}" ]; then
      echo "  ${path}: not local yet"
      printf '%s\t%s\t%s\n' "$path" "$key" "$remote_file" >>"$plan"
    elif files_match "$remote_file" "${REPO_ROOT}/${path}"; then
      echo "  ${path}: same"
    else
      description="$(change_description "$remote_file" "${REPO_ROOT}/${path}")"
      echo "  ${path}: would change ${description}"
      printf '%s\t%s\t%s\n' "$path" "$key" "$remote_file" >>"$plan"
    fi
  done <<<"$keys"

  PULL_ELIGIBLE="$eligible"
}

SCRATCH_DIR="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

case "$MODE" in
diff)
  echo "==> local vs ${PREFIX}"
  keys="$(remote_keys)" || exit 1
  plan_push "differs in" "$keys" "${SCRATCH_DIR}/push-plan"
  [ -s "${SCRATCH_DIR}/push-plan" ] || echo "  (nothing to push)"
  ;;

push)
  echo "==> about to overwrite ${PREFIX}"
  keys="$(remote_keys)" || exit 1
  plan="${SCRATCH_DIR}/push-plan"
  plan_push "would change" "$keys" "$plan"
  if [ ! -s "$plan" ]; then
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
  done <"$plan"
  ;;

pull)
  # Listing up front, not in a process substitution feeding the loop: there its
  # failure would arrive as end of input and read as an empty bucket.
  keys="$(remote_keys)" || exit 1
  if [ -z "$keys" ]; then
    echo "  nothing pulled - ${PREFIX}/ is empty"
    exit 0
  fi

  echo "==> about to overwrite local terraform.tfvars"
  plan="${SCRATCH_DIR}/pull-plan"
  PULL_ELIGIBLE=0
  plan_pull "$keys" "$plan"
  if [ ! -s "$plan" ]; then
    if [ "$PULL_ELIGIBLE" -eq 0 ]; then
      echo "  nothing pulled - every key was skipped"
    else
      echo "  nothing to pull"
    fi
    exit 0
  fi
  if [ -t 0 ]; then
    read -r -p "pull these? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }
  fi
  while IFS=$'\t' read -r path _key remote_file; do
    cp "$remote_file" "${REPO_ROOT}/${path}"
    echo "  pulled ${path}"
  done <"$plan"
  ;;
esac

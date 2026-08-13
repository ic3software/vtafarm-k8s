#!/usr/bin/env bash
# Delete contexts found in a source kubeconfig from ~/.kube/config.
# Usage: delete-kube-context.sh <source-kubeconfig> [destination]
set -euo pipefail

SRC="${1:?usage: delete-kube-context.sh <source-kubeconfig> [destination]}"
DEST="${2:-${HOME}/.kube/config}"

command -v kubectl >/dev/null 2>&1 || {
  echo "ERROR: kubectl not found in PATH" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq not found in PATH" >&2
  exit 1
}
[ -f "$SRC" ] || {
  echo "ERROR: source kubeconfig not found: ${SRC}" >&2
  exit 1
}
[ -f "$DEST" ] || {
  echo "ERROR: destination kubeconfig not found: ${DEST}" >&2
  exit 1
}

context_names() {
  kubectl --kubeconfig "$1" config get-contexts -o name 2>/dev/null
}

SOURCE_CONTEXTS="$(context_names "$SRC")"
EXISTING_CONTEXTS="$(context_names "$DEST")"
TARGET_CONTEXTS=""

while IFS= read -r name; do
  [ -n "$name" ] || continue
  if printf '%s\n' "$EXISTING_CONTEXTS" | grep -qxF "$name"; then
    TARGET_CONTEXTS="${TARGET_CONTEXTS}${name}"$'\n'
  fi
done <<<"$SOURCE_CONTEXTS"

[ -n "$TARGET_CONTEXTS" ] || {
  echo "==> no matching contexts found in ${DEST}"
  exit 0
}

echo "==> contexts to delete from ${DEST}:"
printf '%s' "$TARGET_CONTEXTS" | sed 's/^/    /'
read -r -p "Continue? [y/N] " confirm
case "$confirm" in [yY] | [yY][eE][sS]) ;; *) echo "==> aborted"; exit 0 ;; esac

BACKUP="${DEST}.backup.$(date +%Y%m%d-%H%M%S)"
cp "$DEST" "$BACKUP"
echo "==> backed up ${DEST} to ${BACKUP}"

while IFS= read -r name; do
  [ -n "$name" ] || continue

  CONFIG_JSON="$(kubectl --kubeconfig "$DEST" config view -o json)"
  CLUSTER="$(printf '%s' "$CONFIG_JSON" | jq -r --arg name "$name" '.contexts[] | select(.name == $name) | .context.cluster // empty')"
  USER="$(printf '%s' "$CONFIG_JSON" | jq -r --arg name "$name" '.contexts[] | select(.name == $name) | .context.user // empty')"

  kubectl --kubeconfig "$DEST" config delete-context "$name"

  CONFIG_JSON="$(kubectl --kubeconfig "$DEST" config view -o json)"
  if [ -n "$CLUSTER" ] && ! printf '%s' "$CONFIG_JSON" |
    jq -e --arg value "$CLUSTER" 'any(.contexts[]?; .context.cluster == $value)' >/dev/null; then
    kubectl --kubeconfig "$DEST" config delete-cluster "$CLUSTER"
  fi
  if [ -n "$USER" ] && ! printf '%s' "$CONFIG_JSON" |
    jq -e --arg value "$USER" 'any(.contexts[]?; .context.user == $value)' >/dev/null; then
    kubectl --kubeconfig "$DEST" config delete-user "$USER"
  fi
done <<<"$TARGET_CONTEXTS"

echo "==> remaining contexts:"
kubectl --kubeconfig "$DEST" config get-contexts

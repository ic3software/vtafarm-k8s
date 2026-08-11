#!/usr/bin/env bash
#
# Merges the cluster's kubeconfig into ~/.kube/config so it sits alongside your
# other clusters and can be selected with `kubectl config use-context`.
#
# Safe to re-run: entries with the same name are replaced, and the destination
# is backed up first.
#
# Usage: merge-kubeconfig.sh <source-kubeconfig> [destination]
set -euo pipefail

SRC="${1:?usage: merge-kubeconfig.sh <source-kubeconfig> [destination]}"
DEST="${2:-${HOME}/.kube/config}"

command -v kubectl >/dev/null 2>&1 || {
  echo "==> ERROR: kubectl not found in PATH" >&2
  exit 1
}

[ -f "$SRC" ] || {
  cat >&2 <<EOF
==> ERROR: no kubeconfig at ${SRC}
    Run 'make apply' (or 'make kubeconfig' if the cluster already exists) first.
EOF
  exit 1
}

context_names() { KUBECONFIG="$1" kubectl config view -o jsonpath='{range .contexts[*]}{.name}{"\n"}{end}'; }

NEW_CONTEXTS="$(context_names "$SRC")"
[ -n "$NEW_CONTEXTS" ] || {
  echo "==> ERROR: ${SRC} defines no contexts" >&2
  exit 1
}

mkdir -p "$(dirname "$DEST")"

# Nothing to merge into: just install it.
if [ ! -s "$DEST" ]; then
  install -m 600 "$SRC" "$DEST"
  echo "==> ${DEST} did not exist - installed the cluster kubeconfig there"
  echo "==> contexts now available:"
  KUBECONFIG="$DEST" kubectl config get-contexts
  exit 0
fi

BACKUP="${DEST}.backup.$(date +%Y%m%d-%H%M%S)"
cp "$DEST" "$BACKUP"
echo "==> backed up ${DEST} to ${BACKUP}"

# Drop any same-named entries so a re-run updates in place rather than being
# silently ignored - on a duplicate key, `kubectl config view --flatten` keeps
# whichever file came first in KUBECONFIG.
EXISTING="$(context_names "$DEST" || true)"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if printf '%s\n' "$EXISTING" | grep -qxF "$name"; then
    echo "==> replacing existing entries named '${name}'"
    kubectl --kubeconfig "$DEST" config delete-context "$name" >/dev/null 2>&1 || true
    kubectl --kubeconfig "$DEST" config delete-cluster "$name" >/dev/null 2>&1 || true
    kubectl --kubeconfig "$DEST" config delete-user "$name" >/dev/null 2>&1 || true
  fi
done <<<"$NEW_CONTEXTS"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
KUBECONFIG="${DEST}:${SRC}" kubectl config view --flatten >"$TMP"

# Refuse to install an empty or unparseable result rather than destroying the
# file we just merged from.
KUBECONFIG="$TMP" kubectl config view >/dev/null

install -m 600 "$TMP" "$DEST"

echo "==> merged into ${DEST}"
echo
KUBECONFIG="$DEST" kubectl config get-contexts
echo
while IFS= read -r name; do
  [ -n "$name" ] || continue
  echo "    kubectl config use-context ${name}"
done <<<"$NEW_CONTEXTS"

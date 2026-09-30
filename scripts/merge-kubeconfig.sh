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

# The first file wins on duplicate names. Build beside DEST so the final rename
# is atomic, and never delete entries from the live file while building a merge.
TMP="$(mktemp "${DEST}.tmp.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
if [ -s "$DEST" ]; then
  CURRENT="$(kubectl --kubeconfig "$DEST" config view -o jsonpath='{.current-context}')"
  KUBECONFIG="${SRC}:${DEST}" kubectl config view --flatten --raw >"$TMP"
  if [ -n "$CURRENT" ]; then
    kubectl --kubeconfig "$TMP" config set current-context "$CURRENT" >/dev/null
  else
    kubectl --kubeconfig "$TMP" config unset current-context >/dev/null
  fi
else
  kubectl --kubeconfig "$SRC" config view --flatten --raw >"$TMP"
fi

# Refuse to install an empty or unparseable result rather than destroying the
# file we just merged from.
KUBECONFIG="$TMP" kubectl config view >/dev/null
[ -n "$(context_names "$TMP")" ] || { echo "==> ERROR: empty merged config" >&2; exit 1; }

if [ -s "$DEST" ]; then
  BACKUP="$(mktemp "${DEST}.backup.XXXXXX")"
  cp "$DEST" "$BACKUP"
  chmod 600 "$BACKUP"
  echo "==> backed up ${DEST} to ${BACKUP}"
fi
chmod 600 "$TMP"
mv "$TMP" "$DEST"

echo "==> merged into ${DEST}"
echo
KUBECONFIG="$DEST" kubectl config get-contexts
echo
while IFS= read -r name; do
  [ -n "$name" ] || continue
  echo "    kubectl config use-context ${name}"
done <<<"$NEW_CONTEXTS"

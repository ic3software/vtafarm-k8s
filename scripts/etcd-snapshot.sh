#!/usr/bin/env bash
#
# Thin wrapper around `k3s etcd-snapshot` on the first control-plane node.
#
#   ./scripts/etcd-snapshot.sh save [name]     take an on-demand snapshot
#   ./scripts/etcd-snapshot.sh list            list local + S3 snapshots
#   ./scripts/etcd-snapshot.sh prune           drop snapshots beyond retention
#   ./scripts/etcd-snapshot.sh delete <name>   delete one snapshot
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA="${ROOT}/stacks/01-infra"

HOST="$(tofu -chdir="$INFRA" output -json server_nodes | jq -r '.[0].public_ip')"
KEY="$(tofu -chdir="$INFRA" output -raw ssh_private_key_path 2>/dev/null || echo "$HOME/.ssh/id_ed25519")"

SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

# `k3s etcd-snapshot` reads the server's config.yaml by default, then warns
# about every server-only key it does not understand. Build a private,
# short-lived config containing only options accepted by the snapshot CLI. This
# keeps real errors visible while avoiding misleading "Unknown flag" warnings.
run_snapshot() {
  local remote_command="bash -s --"
  local arg quoted_arg

  for arg in "$@"; do
    printf -v quoted_arg '%q' "$arg"
    remote_command+=" ${quoted_arg}"
  done

  ssh "${SSH_OPTS[@]}" "root@${HOST}" "$remote_command" <<'REMOTE'
set -euo pipefail

readonly server_config=/etc/rancher/k3s/config.yaml
snapshot_config="$(mktemp)"
cleanup() { rm -f "$snapshot_config"; }
trap cleanup EXIT
chmod 0600 "$snapshot_config"

# OpenTofu renders these values as scalar, top-level YAML entries. Include
# data-dir/node-name as well so future overrides still point the CLI at the
# correct local member and snapshot directory.
if ! grep -E \
  '^[[:space:]]*"?(data-dir|node-name|etcd-snapshot-(dir|compress|retention)|etcd-s3(-[a-z0-9-]+)?)"?[[:space:]]*:' \
  "$server_config" >"$snapshot_config"; then
  echo "error: no etcd snapshot settings found in ${server_config}" >&2
  exit 1
fi

action="$1"
shift
k3s etcd-snapshot "$action" --config "$snapshot_config" "$@"
REMOTE
}

ACTION="${1:-list}"
shift || true

case "$ACTION" in
save)
  NAME="${1:-manual-$(date +%Y%m%d-%H%M%S)}"
  echo "==> taking snapshot '${NAME}' on ${HOST}"
  run_snapshot save --name "$NAME"

  # k3s appends the node name and a timestamp, so the file is not named what
  # was asked for. Restoring needs that exact name; read it back.
  FILE="$(run_snapshot list 2>/dev/null | awk -v n="$NAME" '$1 ~ "^" n "-" { print $1 }' | sort -u | tail -1)"
  if [ -n "$FILE" ]; then
    printf '\n==> saved as\n\n    %s\n\n    restore it with: make restore SNAPSHOT=%s\n' "$FILE" "$FILE"
  fi
  ;;
list)
  echo "==> snapshots known to the cluster (local disk and S3)"
  run_snapshot list
  ;;
prune)
  run_snapshot prune
  ;;
delete)
  [ $# -ge 1 ] || {
    echo "usage: $0 delete <snapshot-name>" >&2
    exit 1
  }
  run_snapshot delete "$@"
  ;;
*)
  echo "usage: $0 {save [name]|list|prune|delete <name>}" >&2
  exit 1
  ;;
esac

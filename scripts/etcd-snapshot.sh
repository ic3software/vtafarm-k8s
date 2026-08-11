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

HOST="$(terraform -chdir="$INFRA" output -json server_nodes | jq -r '.[0].public_ip')"
KEY="$(terraform -chdir="$INFRA" output -raw ssh_private_key_path 2>/dev/null || echo "$HOME/.ssh/id_ed25519")"

SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
run() { ssh "${SSH_OPTS[@]}" "root@${HOST}" "$@"; }

ACTION="${1:-list}"
shift || true

case "$ACTION" in
save)
  NAME="${1:-manual-$(date +%Y%m%d-%H%M%S)}"
  echo "==> taking snapshot '${NAME}' on ${HOST}"
  run "k3s etcd-snapshot save --name '${NAME}'"
  ;;
list)
  echo "==> snapshots known to the cluster (local disk and S3)"
  run "k3s etcd-snapshot list"
  ;;
prune)
  run "k3s etcd-snapshot prune"
  ;;
delete)
  [ $# -ge 1 ] || {
    echo "usage: $0 delete <snapshot-name>" >&2
    exit 1
  }
  run "k3s etcd-snapshot delete $*"
  ;;
*)
  echo "usage: $0 {save [name]|list|prune|delete <name>}" >&2
  exit 1
  ;;
esac

#!/usr/bin/env bash
#
# Restore the management cluster from an etcd snapshot, across all servers.
#
#   ./scripts/etcd-restore.sh <snapshot-file>           from S3
#   ./scripts/etcd-restore.sh --local <snapshot-file>   from server-1's disk
#   ./scripts/etcd-restore.sh --yes <snapshot-file>     skip the confirmation
#
# The cluster is unavailable while this runs. Downstream clusters keep serving:
# they have their own etcd and their kubeconfigs do not go through Rancher.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA="${ROOT}/stacks/01-infra"

FROM_S3=true
ASSUME_YES=false
SNAPSHOT=""

while [ $# -gt 0 ]; do
  case "$1" in
  --local) FROM_S3=false ;;
  --yes | -y) ASSUME_YES=true ;;
  -h | --help)
    sed -n '3,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  -*)
    echo "unknown option: $1" >&2
    exit 2
    ;;
  *) SNAPSHOT="$1" ;;
  esac
  shift
done

[ -n "$SNAPSHOT" ] || {
  echo "usage: $0 [--local] [--yes] <snapshot-file>" >&2
  echo "       ./scripts/etcd-snapshot.sh list   # to find one" >&2
  exit 2
}

NODES="$(tofu -chdir="$INFRA" output -json server_nodes)"
KEY="$(tofu -chdir="$INFRA" output -raw ssh_private_key_path 2>/dev/null || echo "$HOME/.ssh/id_ed25519")"
SSH_OPTS=(-i "$KEY" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

FIRST_IP="$(jq -r '.[0].public_ip' <<<"$NODES")"
FIRST_NAME="$(jq -r '.[0].name' <<<"$NODES")"

# jq does the indexing so this behaves the same under bash and zsh, whose
# arrays are indexed differently.
all_ips() { jq -r '.[].public_ip' <<<"$NODES"; }
rest_ips() { jq -r '.[1:][].public_ip' <<<"$NODES"; }

# -n keeps ssh off the loop's stdin, which it would otherwise swallow.
on_node() { ssh -n "${SSH_OPTS[@]}" "root@${1}" "${2}"; }

log() { printf '==> %s\n' "$*"; }

if [ "$ASSUME_YES" = false ]; then
  echo "This restores the management cluster to the state inside:"
  echo
  echo "    ${SNAPSHOT}   ($([ "$FROM_S3" = true ] && echo "from S3" || echo "from local disk"))"
  echo
  echo "Every change made after that snapshot is lost. k3s stops on all"
  echo "$(all_ips | wc -l | tr -d ' ') servers, is reset on ${FIRST_NAME}, and the others rejoin empty."
  echo
  read -r -p "Type the cluster name to continue: " reply
  [ "$reply" = "$(jq -r '.[0].name' <<<"$NODES" | sed 's/-server-1$//')" ] || {
    echo "aborted" >&2
    exit 1
  }
fi

log "stopping k3s on every server"
all_ips | while read -r ip; do
  echo "    ${ip}"
  on_node "$ip" 'systemctl stop k3s'
done

log "restoring on ${FIRST_NAME} (${FIRST_IP})"

if [ "$FROM_S3" = true ]; then
  RESET_FLAGS="--etcd-s3 --cluster-reset-restore-path=${SNAPSHOT}"
else
  case "$SNAPSHOT" in
  /*) path="$SNAPSHOT" ;;
  *) path="/var/lib/rancher/k3s/server/db/snapshots/${SNAPSHOT}" ;;
  esac
  # config.yaml turns etcd-s3 on, which would make k3s read the path as an S3 key.
  RESET_FLAGS="--etcd-s3=false --cluster-reset-restore-path=${path}"
fi

# `k3s server --cluster-reset` does not exit on its own: it prints the "restart
# without --cluster-reset" line and keeps running, expecting an interactive
# Ctrl-C. Watch the log for that line instead, then stop it.
ssh "${SSH_OPTS[@]}" "root@${FIRST_IP}" "bash -s -- ${RESET_FLAGS}" <<'REMOTE'
set -euo pipefail

readonly done_line='Managed etcd cluster membership has been reset'
readonly log=/var/lib/rancher/k3s/server/db/cluster-reset.log

rm -f "$log"
k3s server --cluster-reset "$@" >"$log" 2>&1 &
pid=$!

reset_done=false
for _ in $(seq 1 180); do
  if grep -qF "$done_line" "$log" 2>/dev/null; then
    reset_done=true
    break
  fi
  kill -0 "$pid" 2>/dev/null || break
  sleep 5
done

kill -TERM "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true

if [ "$reset_done" = false ]; then
  echo "--- last 40 lines of ${log} ---" >&2
  tail -40 "$log" >&2
  echo "error: the cluster reset did not report success" >&2
  exit 1
fi

systemctl start k3s
REMOTE

log "the other servers rejoin as fresh members"
rest_ips | while read -r ip; do
  echo "    ${ip}"
  on_node "$ip" 'rm -rf /var/lib/rancher/k3s/server/db/ && systemctl start k3s'
done

log "waiting for the API server"
for _ in $(seq 1 60); do
  if on_node "$FIRST_IP" 'k3s kubectl get --raw /readyz' >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

log "nodes"
on_node "$FIRST_IP" 'k3s kubectl get nodes'

cat <<EOF

Restored. Rancher lives in etcd and comes back with it - give it five minutes,
then:

  export KUBECONFIG=${INFRA}/kubeconfig.yaml
  kubectl -n cattle-system get pods
EOF

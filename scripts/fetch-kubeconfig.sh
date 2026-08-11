#!/usr/bin/env bash
#
# Copies /etc/rancher/k3s/k3s.yaml off the first server and rewrites the API
# endpoint so it points at the load balancer instead of 127.0.0.1.
#
# Usage: fetch-kubeconfig.sh <ssh-host> <ssh-key> <api-endpoint> <out-path> <context-name>
set -euo pipefail

SSH_HOST="$1"
SSH_KEY="$2"
API_ENDPOINT="$3"
OUT="$4"
CONTEXT="${5:-k3s}"

SSH_OPTS=(
  -i "$SSH_KEY"
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -o LogLevel=ERROR
)

echo "==> waiting for k3s to finish bootstrapping on ${SSH_HOST} (up to 20 min)"
ready=0
for i in $(seq 1 120); do
  if ssh "${SSH_OPTS[@]}" "root@${SSH_HOST}" \
    'test -f /var/lib/rancher/.k3s-bootstrap-done && test -f /etc/rancher/k3s/k3s.yaml' 2>/dev/null; then
    ready=1
    break
  fi
  printf '    still waiting (%s/120)\r' "$i"
  sleep 10
done
echo

if [ "$ready" -ne 1 ]; then
  cat >&2 <<EOF
==> ERROR: k3s did not come up on ${SSH_HOST}.
    Inspect the bootstrap log with:
      ssh root@${SSH_HOST} 'tail -100 /var/log/cloud-init-output.log'
      ssh root@${SSH_HOST} 'journalctl -u k3s -n 200 --no-pager'
EOF
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

ssh "${SSH_OPTS[@]}" "root@${SSH_HOST}" 'cat /etc/rancher/k3s/k3s.yaml' |
  sed -e "s#https://127.0.0.1:6443#${API_ENDPOINT}#" \
    -e "s/default/${CONTEXT}/g" >"${OUT}.tmp"

mv "${OUT}.tmp" "$OUT"
chmod 600 "$OUT"

echo "==> kubeconfig written to ${OUT}"
echo "    export KUBECONFIG=\"\$(cd \"\$(dirname \"${OUT}\")\" && pwd)/\$(basename \"${OUT}\")\""

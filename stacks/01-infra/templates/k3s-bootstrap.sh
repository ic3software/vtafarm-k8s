#!/usr/bin/env bash
#
# Runs once at first boot, from cloud-init. Everything it needs is in
# /etc/k3s-bootstrap.env, which Terraform renders per node.
#
# Logs land in /var/log/cloud-init-output.log.
set -euo pipefail

# shellcheck disable=SC1091
source /etc/k3s-bootstrap.env

# Assert what the env file has to provide. Without this, a variable dropped from
# the Terraform side surfaces as "unbound variable" on whichever line happens to
# use it first - which may be minutes into the run, after the node looks healthy.
: "${NODE_IP:?not set in /etc/k3s-bootstrap.env}"
: "${K3S_VERSION:?not set in /etc/k3s-bootstrap.env}"

log() { echo "[k3s-bootstrap] $(date -Is) $*"; }

# ---------------------------------------------------------------------------
# 1. Wait for the Hetzner private network to be attached.
#
# cloud-init frequently runs before the second NIC is configured. k3s must bind
# to the private IP, so we block until it exists and then record the interface
# name for flannel (it differs between Intel/AMD/ARM instance types, so it is
# detected here rather than hard-coded).
# ---------------------------------------------------------------------------
IFACE=""
for _ in $(seq 1 60); do
  IFACE="$(ip -o -4 addr show | awk -v pfx="${NODE_IP}/" '$4 ~ "^"pfx {print $2; exit}')"
  [ -n "$IFACE" ] && break
  log "waiting for private IP ${NODE_IP} to appear ..."
  sleep 5
done

if [ -z "$IFACE" ]; then
  log "ERROR: private IP ${NODE_IP} never appeared on any interface"
  # Print link state as well as addresses: an interface that is present but
  # DOWN with no address means the network was hot-plugged after cloud-init
  # configured networking, rather than attached at server creation.
  ip -o link show
  ip -o -4 addr show
  exit 1
fi
log "private interface for ${NODE_IP} is ${IFACE}"

# k3s merges every *.yaml in config.yaml.d over /etc/rancher/k3s/config.yaml.
install -d -m 0700 /etc/rancher/k3s/config.yaml.d
cat >/etc/rancher/k3s/config.yaml.d/10-node.yaml <<EOF
flannel-iface: ${IFACE}
EOF
chmod 0600 /etc/rancher/k3s/config.yaml.d/10-node.yaml

# ---------------------------------------------------------------------------
# 2. Wait for the nodes this one depends on.
#
# The k3s supervisor serves /cacerts unauthenticated as soon as it is listening,
# which makes it a dependable "ready to be joined" probe. Node 0 has no peers
# and skips this loop entirely.
# ---------------------------------------------------------------------------
for peer in ${WAIT_FOR_PEERS:-}; do
  log "waiting for peer ${peer} ..."
  reachable=0
  for _ in $(seq 1 240); do
    if curl -sk --max-time 5 "https://${peer}:6443/cacerts" >/dev/null 2>&1; then
      reachable=1
      break
    fi
    sleep 5
  done
  if [ "$reachable" -ne 1 ]; then
    log "ERROR: peer ${peer} never became reachable (waited 20m)"
    exit 1
  fi
  log "peer ${peer} is up"
done

# etcd is happier when members are added one at a time.
if [ "${JOIN_DELAY:-0}" -gt 0 ]; then
  log "staggering join by ${JOIN_DELAY}s"
  sleep "${JOIN_DELAY}"
fi

# ---------------------------------------------------------------------------
# 3. Install k3s. Every node in this cluster is a server; all configuration
#    comes from /etc/rancher/k3s/config.yaml, so the installer only needs the
#    version.
# ---------------------------------------------------------------------------
log "installing k3s ${K3S_VERSION}"
curl -sfL https://get.k3s.io |
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
    INSTALL_K3S_EXEC="server" \
    sh -s -

# ---------------------------------------------------------------------------
# 4. Confirm the unit is actually healthy before declaring success.
# ---------------------------------------------------------------------------
log "waiting for k3s.service"
for _ in $(seq 1 120); do
  systemctl is-active --quiet k3s && break
  sleep 5
done

if ! systemctl is-active --quiet k3s; then
  log "ERROR: k3s.service did not start"
  journalctl -u k3s -n 200 --no-pager || true
  exit 1
fi

install -d -m 0755 /var/lib/rancher
touch /var/lib/rancher/.k3s-bootstrap-done
log "k3s is running - bootstrap complete"

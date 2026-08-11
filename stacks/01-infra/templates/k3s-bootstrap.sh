#!/usr/bin/env bash
#
# Runs once at first boot, from cloud-init. Everything it needs is in
# /etc/k3s-bootstrap.env, which Terraform renders per node.
#
# Logs land in /var/log/cloud-init-output.log.
set -euo pipefail

STATUS_DIR="/var/lib/rancher"
DONE_MARKER="${STATUS_DIR}/.k3s-bootstrap-done"
FAILED_MARKER="${STATUS_DIR}/.k3s-bootstrap-failed"
install -d -m 0755 "$STATUS_DIR"
rm -f "$DONE_MARKER" "$FAILED_MARKER"

record_failure() {
  status=$?
  if [ "$status" -ne 0 ]; then
    printf 'bootstrap failed with exit status %s at %s\n' \
      "$status" "$(date -Is)" >"$FAILED_MARKER"
  fi
}
trap record_failure EXIT

# shellcheck disable=SC1091
source /etc/k3s-bootstrap.env

# Assert what the env file has to provide. Without this, a variable dropped from
# the Terraform side surfaces as "unbound variable" on whichever line happens to
# use it first - which may be minutes into the run, after the node looks healthy.
: "${NODE_IP:?not set in /etc/k3s-bootstrap.env}"
: "${K3S_VERSION:?not set in /etc/k3s-bootstrap.env}"

log() { echo "[k3s-bootstrap] $(date -Is) $*"; }

interface_with_ip() {
  ip -o -4 addr show |
    awk -v pfx="${NODE_IP}/" '$4 ~ "^"pfx {print $2; exit}'
}

find_private_interface() {
  public_interface="$1"

  for interface_path in /sys/class/net/*; do
    interface="${interface_path##*/}"
    [ "$interface" = "lo" ] && continue
    [ "$interface" = "$public_interface" ] && continue
    # Ignore software interfaces if the image happens to provide any. Both
    # Hetzner virtio NICs have a device entry under /sys/class/net.
    [ -e "${interface_path}/device" ] || continue
    printf '%s\n' "$interface"
    return 0
  done

  return 1
}

configure_private_interface() {
  interface="$1"
  mac_address="$(cat "/sys/class/net/${interface}/address")"

  case "$mac_address" in
    ??:??:??:??:??:??) ;;
    *)
      log "ERROR: could not determine the MAC address of ${interface}"
      return 1
      ;;
  esac

  log "configuring private interface ${interface} (${mac_address}) with netplan DHCP"
  cat >/etc/netplan/60-k3s-private-network.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    k3s-private:
      match:
        macaddress: "${mac_address}"
      dhcp4: true
      dhcp4-overrides:
        use-dns: false
      dhcp6: false
      mtu: 1450
      optional: true
EOF
  chmod 0600 /etc/netplan/60-k3s-private-network.yaml

  if ! netplan generate; then
    log "ERROR: netplan rejected the private interface configuration"
    return 1
  fi
  if ! netplan apply; then
    log "ERROR: netplan could not activate private interface ${interface}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# 1. Configure the Hetzner private network.
#
# The hcloud provider can attach the private NIC after the server has started.
# In that case cloud-init has already completed its network stage, leaving the
# hot-plugged NIC DOWN and without an address. Detect the NIC by excluding the
# public default-route interface, persist a MAC-matched netplan definition, and
# actively run DHCP. The interface name differs across instance types, so it is
# never hard-coded.
# ---------------------------------------------------------------------------
PUBLIC_IFACE="$(ip -o -4 route show default | awk '{print $5; exit}')"
if [ -z "$PUBLIC_IFACE" ]; then
  log "ERROR: could not identify the public default-route interface"
  ip -o -4 route show || true
  exit 1
fi

IFACE=""
PRIVATE_IFACE=""
NETPLAN_CONFIGURED=0
for _ in $(seq 1 60); do
  IFACE="$(interface_with_ip)"
  [ -n "$IFACE" ] && break

  if [ -z "$PRIVATE_IFACE" ]; then
    PRIVATE_IFACE="$(find_private_interface "$PUBLIC_IFACE" || true)"
  fi

  if [ -z "$PRIVATE_IFACE" ]; then
    log "waiting for the private network interface to appear ..."
  elif [ "$NETPLAN_CONFIGURED" -eq 0 ]; then
    configure_private_interface "$PRIVATE_IFACE"
    NETPLAN_CONFIGURED=1
    log "waiting for private IP ${NODE_IP} on ${PRIVATE_IFACE} ..."
  else
    log "waiting for private IP ${NODE_IP} on ${PRIVATE_IFACE} ..."
  fi
  sleep 5
done

if [ -z "$IFACE" ]; then
  log "ERROR: private IP ${NODE_IP} never appeared on any interface"
  ip -o link show
  ip -o -4 addr show
  ip -o -4 route show
  sed -n '1,200p' /etc/netplan/60-k3s-private-network.yaml 2>/dev/null || true
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

rm -f "$FAILED_MARKER"
touch "$DONE_MARKER"
log "k3s is running - bootstrap complete"

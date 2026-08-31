#!/usr/bin/env bash
# Configure the hot-plugged Hetzner private NIC when enabled, then run Rancher's
# generated system-agent registration command. Logs are in cloud-init-output.log.
set -euo pipefail

STATUS_DIR="/var/lib/rancher"
DONE_MARKER="${STATUS_DIR}/.rancher-node-bootstrap-done"
FAILED_MARKER="${STATUS_DIR}/.rancher-node-bootstrap-failed"
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
source /etc/rancher-node-bootstrap.env
: "${USE_PRIVATE_NETWORK:?not set in /etc/rancher-node-bootstrap.env}"

if [ "$USE_PRIVATE_NETWORK" = "true" ]; then
  : "${NODE_PRIVATE_IP:?not set in /etc/rancher-node-bootstrap.env}"
  : "${PRIVATE_NETWORK_CIDR:?not set in /etc/rancher-node-bootstrap.env}"
  : "${PRIVATE_NETWORK_GATEWAY:?not set in /etc/rancher-node-bootstrap.env}"
  : "${PRIVATE_IFACE_MTU:?not set in /etc/rancher-node-bootstrap.env}"
fi

log() { echo "[rancher-node-bootstrap] $(date -Is) $*"; }

interface_with_ip() {
  ip -o -4 addr show |
    awk -v pfx="${NODE_PRIVATE_IP}/" '$4 ~ "^"pfx {print $2; exit}'
}

find_private_interface() {
  public_interface="$1"

  for interface_path in /sys/class/net/*; do
    interface="${interface_path##*/}"
    [ "$interface" = "lo" ] && continue
    [ "$interface" = "$public_interface" ] && continue
    [ -e "${interface_path}/device" ] || continue
    printf '%s\n' "$interface"
    return 0
  done

  return 1
}

configure_private_interface() {
  interface="$1"
  mac_address="$(cat "/sys/class/net/${interface}/address")"

  log "configuring private interface ${interface} (${mac_address}) with netplan DHCP"
  cat >/etc/netplan/60-rke2-private-network.yaml <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${interface}:
      match:
        macaddress: "${mac_address}"
      dhcp4: true
      dhcp4-overrides:
        use-dns: false
        use-routes: false
      dhcp6: false
      mtu: ${PRIVATE_IFACE_MTU}
      optional: true
      routes:
        - to: ${PRIVATE_NETWORK_GATEWAY}/32
          scope: link
        - to: ${PRIVATE_NETWORK_CIDR}
          via: ${PRIVATE_NETWORK_GATEWAY}
EOF
  chmod 0600 /etc/netplan/60-rke2-private-network.yaml
  netplan generate
  netplan apply
}

if [ "$USE_PRIVATE_NETWORK" = "true" ]; then
  PUBLIC_IFACE="$(ip -o -4 route show default | awk '{print $5; exit}')"
  if [ -z "$PUBLIC_IFACE" ]; then
    log "ERROR: could not identify the public interface"
    exit 1
  fi

  # Hetzner attaches the private NIC just after the server is created, so
  # whether cloud-init's metadata already carries it is a race on each node.
  IFACE=""
  DETECTED_IFACE=""
  NETPLAN_CONFIGURED=0
  for _ in $(seq 1 60); do
    IFACE="$(interface_with_ip)"
    [ -n "$IFACE" ] && break

    if [ -z "$DETECTED_IFACE" ]; then
      DETECTED_IFACE="$(find_private_interface "$PUBLIC_IFACE" || true)"
    fi

    if [ -z "$DETECTED_IFACE" ]; then
      log "waiting for the private network interface"
    elif [ "$NETPLAN_CONFIGURED" -eq 0 ]; then
      configure_private_interface "$DETECTED_IFACE"
      NETPLAN_CONFIGURED=1
    else
      log "waiting for private IP ${NODE_PRIVATE_IP}"
    fi
    sleep 5
  done

  if [ -z "$IFACE" ]; then
    log "ERROR: private IP ${NODE_PRIVATE_IP} never appeared"
    ip -o link show || true
    ip -o -4 addr show || true
    exit 1
  fi
fi

log "registering node with Rancher"
/bin/bash /etc/rancher/node-registration.sh
rm -f /etc/rancher/node-registration.sh

log "waiting for rancher-system-agent.service"
for _ in $(seq 1 120); do
  systemctl is-active --quiet rancher-system-agent.service && break
  sleep 5
done

if ! systemctl is-active --quiet rancher-system-agent.service; then
  log "ERROR: rancher-system-agent.service did not become active"
  journalctl -u rancher-system-agent -n 200 --no-pager || true
  exit 1
fi

rm -f "$FAILED_MARKER"
touch "$DONE_MARKER"
log "registration complete; Rancher will now converge the RKE2 plan"

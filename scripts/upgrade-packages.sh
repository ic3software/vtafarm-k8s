#!/usr/bin/env bash
#
# Roll Ubuntu package updates across the nodes of one cluster, one node at a
# time. This is `apt update && apt upgrade`, sequenced so a kernel update never
# reboots two etcd members at once.
#
# Usage:
#   make upgrade-packages-check                 report what is pending, change nothing
#   make upgrade-packages                       upgrade the k3s cluster (stack 01)
#   make upgrade-packages CLUSTER=name          upgrade a downstream RKE2 cluster
#
# k3s, RKE2 and their bundled containerd are installed outside apt, so nothing
# here can move the Kubernetes version. Only the Ubuntu packages underneath it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA="${ROOT}/stacks/01-infra"
CLUSTER="${CLUSTER:-}"
WAIT_TIMEOUT_SECONDS="${UPGRADE_PACKAGES_WAIT_TIMEOUT_SECONDS:-900}"
BETWEEN_NODES_SECONDS="${UPGRADE_PACKAGES_BETWEEN_NODES_SECONDS:-60}"
CHECK_ONLY=false

log() { printf '==> %s\n' "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

ssh_node() {
  local host="$1"
  shift
  ssh \
    -i "$SSH_KEY" \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "root@${host}" "$@"
}

# Prints "<pending>\t<security>\t<yes|no reboot needed>" for one node.
node_report() {
  ssh_node "$1" 'bash -s' <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Ubuntu's own apt timers hold the dpkg lock for minutes at a time, and a node
# that just rebooted is the likeliest moment to collide with one.
apt-get -o DPkg::Lock::Timeout=300 -qq update >/dev/null

# --with-new-pkgs is what makes kernel security updates visible: they arrive as
# a NEW linux-image-* package, which a plain `apt-get upgrade` holds back.
plan="$(apt-get -s -o DPkg::Lock::Timeout=300 --with-new-pkgs upgrade)"
total="$(printf '%s\n' "$plan" | grep -c '^Inst' || true)"
# Most security fixes are published to -updates as well, so the -security origin
# appearing anywhere on the line is the usual way to count them.
security="$(printf '%s\n' "$plan" | grep '^Inst' | grep -c -- '-security' || true)"

reboot=no
if [ -f /var/run/reboot-required ]; then
  reboot=yes
fi

printf '%s\t%s\t%s\n' "$total" "$security" "$reboot"
REMOTE
}

node_upgrade() {
  ssh_node "$1" 'bash -s' <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# List restart candidates instead of acting on them. needrestart would otherwise
# bounce sshd and friends mid-upgrade; the controlled reboot below covers them.
export NEEDRESTART_MODE=l

apt-get -o DPkg::Lock::Timeout=300 -qq update >/dev/null
apt-get -y \
  -o DPkg::Lock::Timeout=300 \
  -o Dpkg::Options::=--force-confold \
  --with-new-pkgs upgrade
REMOTE
}

node_needs_reboot() {
  ssh_node "$1" 'test -f /var/run/reboot-required'
}

node_is_ready() {
  local node="$1"
  [ "$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

wait_for_node_ready() {
  local node="$1"
  local deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))

  while [ "$SECONDS" -lt "$deadline" ]; do
    if node_is_ready "$node"; then
      return 0
    fi
    sleep 10
  done

  return 1
}

# A returning SSH connection is not proof of a reboot - sshd answers again
# before the kernel is replaced if the machine never went down. The boot id is.
wait_for_reboot() {
  local host="$1"
  local previous_boot_id="$2"
  local deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
  local current_boot_id

  while [ "$SECONDS" -lt "$deadline" ]; do
    current_boot_id="$(ssh_node "$host" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
    if [ -n "$current_boot_id" ] && [ "$current_boot_id" != "$previous_boot_id" ]; then
      return 0
    fi
    sleep 5
  done

  return 1
}

etcd_nodes_json() {
  kubectl get nodes -l node-role.kubernetes.io/etcd=true -o json
}

check_cluster_health() {
  local nodes_json total ready healthz

  nodes_json="$(etcd_nodes_json)"
  total="$(printf '%s' "$nodes_json" | jq '.items | length')"
  ready="$(printf '%s' "$nodes_json" |
    jq '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length')"

  [ "$total" -eq "$EXPECTED_ETCD_NODES" ] ||
    die "expected ${EXPECTED_ETCD_NODES} etcd nodes, found ${total}"
  [ "$ready" -eq "$EXPECTED_ETCD_NODES" ] ||
    die "only ${ready} of ${EXPECTED_ETCD_NODES} etcd nodes are Ready"

  # The API server's own etcd probe is the stronger signal, but a Rancher-proxied
  # kubeconfig does not always forward /healthz. Gate on it only when it answers.
  if healthz="$(kubectl get --raw '/healthz?verbose' 2>/dev/null)"; then
    printf '%s\n' "$healthz" | grep -q '\[+\]etcd ok' ||
      die "the API server reports etcd unhealthy"
  fi
}

case "${1:-}" in
--check) CHECK_ONLY=true ;;
"") ;;
*) die "usage: $0 [--check]; select a downstream cluster with CLUSTER=name" ;;
esac

case "$WAIT_TIMEOUT_SECONDS" in '' | *[!0-9]*) die "UPGRADE_PACKAGES_WAIT_TIMEOUT_SECONDS must be a non-negative integer" ;; esac
case "$BETWEEN_NODES_SECONDS" in '' | *[!0-9]*) die "UPGRADE_PACKAGES_BETWEEN_NODES_SECONDS must be a non-negative integer" ;; esac

for command in tofu kubectl jq ssh grep; do
  require_command "$command"
done

if [ -n "$CLUSTER" ]; then
  STACK_DIR="${ROOT}/stacks/03-rke2-clusters/clusters/${CLUSTER}"
  [ -d "$STACK_DIR" ] || die "cluster root does not exist: ${STACK_DIR}"

  KUBECONFIG="${STACK_DIR}/kubeconfig.yaml"
  [ -f "$KUBECONFIG" ] ||
    die "missing ${KUBECONFIG}; run: make kubeconfig-rke2 CLUSTER=${CLUSTER}"

  # Dedicated workers first: they carry no etcd member, so a failure there stops
  # the run before the control plane has been touched. Servers then descend to
  # server-1, the node the rest of the cluster was bootstrapped against.
  NODE_LINES="$(tofu -chdir="$STACK_DIR" output -json nodes 2>/dev/null | jq -r '
    to_entries
    | map({
        name:  .value.name,
        ip:    .value.public_ip,
        group: (if (.key | startswith("worker")) then 0 else 1 end),
        index: (.key | split("-") | last | tonumber)
      })
    | sort_by(.group, -.index)
    | .[] | "\(.name)\t\(.ip)"
  ')" || die "cannot read the OpenTofu nodes output for ${CLUSTER}"
else
  STACK_DIR="$INFRA"
  KUBECONFIG="${KUBECONFIG:-${STACK_DIR}/kubeconfig.yaml}"
  [ -f "$KUBECONFIG" ] ||
    die "missing kubeconfig at ${KUBECONFIG}; deploy the cluster before upgrading it"

  NODE_LINES="$(tofu -chdir="$STACK_DIR" output -json server_nodes 2>/dev/null |
    jq -r '[.[] | "\(.name)\t\(.public_ip)"] | reverse | .[]')" ||
    die "cannot read the OpenTofu server_nodes output; deploy stack 01 first"
fi

export KUBECONFIG

[ -n "$NODE_LINES" ] || die "no nodes found in ${STACK_DIR}"

# Downstream clusters reuse an SSH key that already exists in the Hetzner
# project - normally the one stack 01 owns - so its private half is the same
# file. Override with SSH_KEY= when a cluster uses a different key.
SSH_KEY="${SSH_KEY:-$(tofu -chdir="$INFRA" output -raw ssh_private_key_path 2>/dev/null ||
  echo "${HOME}/.ssh/id_ed25519")}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"
[ -f "$SSH_KEY" ] || die "SSH private key not found: ${SSH_KEY}"

NODES=()
while IFS= read -r line; do
  NODES+=("$line")
done <<<"$NODE_LINES"

# Reporting only needs SSH, which is the whole point of being able to run it
# while the cluster itself is unhappy.
if [ "$CHECK_ONLY" = true ]; then
  log "pending updates on ${#NODES[@]} node(s) of ${CLUSTER:-the k3s cluster}"
  for entry in "${NODES[@]}"; do
    NODE="${entry%%$'\t'*}"
    IP="${entry##*$'\t'}"
    REPORT="$(node_report "$IP")"
    printf '    %-44s %4s pending  %4s security  reboot required: %s\n' \
      "$NODE" \
      "$(printf '%s' "$REPORT" | cut -f1)" \
      "$(printf '%s' "$REPORT" | cut -f2)" \
      "$(printf '%s' "$REPORT" | cut -f3)"
  done
  exit 0
fi

kubectl version --request-timeout=10s >/dev/null 2>&1 ||
  die "cannot reach the Kubernetes API with ${KUBECONFIG}"

EXPECTED_ETCD_NODES="$(etcd_nodes_json | jq '.items | length')"
[ "$EXPECTED_ETCD_NODES" -gt 0 ] || die "no nodes carry the etcd role; is this the right kubeconfig?"

check_cluster_health
log "starting from ${EXPECTED_ETCD_NODES} healthy etcd node(s)"

UPGRADED=0
REBOOTED=0
SKIPPED=0
NODE_INDEX=0

for entry in "${NODES[@]}"; do
  NODE_INDEX=$((NODE_INDEX + 1))
  NODE="${entry%%$'\t'*}"
  IP="${entry##*$'\t'}"

  node_is_ready "$NODE" || die "${NODE} is not Ready; fix that before upgrading packages on it"

  REPORT="$(node_report "$IP")"
  PENDING="$(printf '%s' "$REPORT" | cut -f1)"
  SECURITY="$(printf '%s' "$REPORT" | cut -f2)"
  NEEDS_REBOOT="$(printf '%s' "$REPORT" | cut -f3)"

  if [ "$PENDING" -eq 0 ] && [ "$NEEDS_REBOOT" = no ]; then
    log "${NODE}: already up to date"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # No drain here on purpose: installing packages does not disturb the running
  # kernel, and k3s/RKE2 do not get their container runtime from apt. Only the
  # reboot below can interrupt workloads, so only that step drains.
  if [ "$PENDING" -gt 0 ]; then
    log "${NODE}: upgrading ${PENDING} package(s), ${SECURITY} of them security"
    node_upgrade "$IP"
    UPGRADED=$((UPGRADED + 1))
    if node_needs_reboot "$IP"; then
      NEEDS_REBOOT=yes
    else
      NEEDS_REBOOT=no
    fi
  fi

  if [ "$NEEDS_REBOOT" = no ]; then
    log "${NODE}: done, no reboot needed"
    continue
  fi

  log "${NODE}: reboot required, draining"
  kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=300s ||
    die "could not drain ${NODE}; it stays cordoned until you resolve the eviction and uncordon it"

  BOOT_ID="$(ssh_node "$IP" 'cat /proc/sys/kernel/random/boot_id')"
  # Deferred by a few seconds so sshd survives long enough to report success.
  ssh_node "$IP" 'systemd-run --on-active=5 --timer-property=AccuracySec=100ms systemctl reboot'

  wait_for_reboot "$IP" "$BOOT_ID" ||
    die "${NODE} did not come back within ${WAIT_TIMEOUT_SECONDS}s; it is still cordoned"
  wait_for_node_ready "$NODE" ||
    die "${NODE} rebooted but never returned Ready; it is still cordoned"

  check_cluster_health
  kubectl uncordon "$NODE"
  REBOOTED=$((REBOOTED + 1))
  log "${NODE}: back on $(ssh_node "$IP" 'uname -r')"

  if [ "$NODE_INDEX" -lt "${#NODES[@]}" ] && [ "$BETWEEN_NODES_SECONDS" -gt 0 ]; then
    log "waiting ${BETWEEN_NODES_SECONDS}s before the next node"
    sleep "$BETWEEN_NODES_SECONDS"
  fi
done

check_cluster_health
log "done: ${UPGRADED} node(s) upgraded, ${REBOOTED} rebooted, ${SKIPPED} already current"

# Ubuntu rolls some updates out in phases, so a node can legitimately still
# report packages pending right after a successful run. They land on a later one.
log "re-check with: make upgrade-packages-check${CLUSTER:+ CLUSTER=$CLUSTER}"

#!/usr/bin/env bash
#
# Replace k3s servers with a fresh Hetzner OS image, one at a time.
#
# Usage:
#   make upgrade-os TARGET_IMAGE=ubuntu-26.04
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA="${ROOT}/stacks/01-infra"
TFVARS="${INFRA}/terraform.tfvars"
KUBECONFIG="${KUBECONFIG:-${ROOT}/kubeconfig}"
TARGET_IMAGE="${TARGET_IMAGE:-}"
WAIT_TIMEOUT_SECONDS="${UPGRADE_OS_WAIT_TIMEOUT_SECONDS:-1200}"
BETWEEN_NODES_SECONDS="${UPGRADE_OS_BETWEEN_NODES_SECONDS:-300}"
TEMP_FILE=""

export KUBECONFIG

cleanup() {
  [ -z "$TEMP_FILE" ] || rm -f "$TEMP_FILE"
}
trap cleanup EXIT

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

node_is_ready() {
  local node="$1"
  [ "$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]
}

node_has_etcd_role() {
  local node="$1"
  kubectl get node "$node" -o json 2>/dev/null |
    jq -e '.metadata.labels | has("node-role.kubernetes.io/etcd")' >/dev/null
}

wait_for_new_node() {
  local node="$1"
  local deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))

  log "waiting up to ${WAIT_TIMEOUT_SECONDS}s for ${node} to return Ready with the etcd role"
  while [ "$SECONDS" -lt "$deadline" ]; do
    if node_is_ready "$node" && node_has_etcd_role "$node"; then
      return 0
    fi
    sleep 10
  done

  return 1
}

wait_for_etcd_removal() {
  local node="$1"
  local deadline=$((SECONDS + 180))
  local removed_name

  while [ "$SECONDS" -lt "$deadline" ]; do
    removed_name="$(kubectl get node "$node" \
      -o jsonpath='{.metadata.annotations.etcd\.k3s\.cattle\.io/removed-node-name}' \
      2>/dev/null || true)"
    [ -n "$removed_name" ] && return 0
    sleep 5
  done

  return 1
}

check_cluster_health() {
  local expected_nodes="$1"
  local health_host="$2"
  local ready_count etcd_count

  ready_count="$(kubectl get nodes -l node-role.kubernetes.io/etcd=true -o json |
    jq '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length')"
  etcd_count="$(kubectl get nodes -l node-role.kubernetes.io/etcd=true -o json | jq '.items | length')"

  [ "$ready_count" -eq "$expected_nodes" ] ||
    die "expected ${expected_nodes} Ready nodes, found ${ready_count}"
  [ "$etcd_count" -eq "$expected_nodes" ] ||
    die "expected ${expected_nodes} etcd nodes, found ${etcd_count}"

  ssh_node "$health_host" 'k3s kubectl get --raw "/healthz?verbose"' |
    grep -q '\[+]etcd ok' || die "etcd health check failed on ${health_host}"
}

persist_target_image() {
  local assignment_count

  assignment_count="$(grep -Ec '^[[:space:]]*os_image[[:space:]]*=' "$TFVARS" || true)"
  [ "$assignment_count" -le 1 ] || die "${TFVARS} contains more than one os_image assignment"

  TEMP_FILE="$(mktemp "${TFVARS}.upgrade-os.XXXXXX")"
  chmod 0600 "$TEMP_FILE"

  awk -v target="$TARGET_IMAGE" '
    BEGIN { replaced = 0 }
    /^[[:space:]]*os_image[[:space:]]*=/ {
      print "os_image = \"" target "\""
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) {
        print ""
        print "os_image = \"" target "\""
      }
    }
  ' "$TFVARS" >"$TEMP_FILE"

  mv "$TEMP_FILE" "$TFVARS"
  TEMP_FILE=""
}

current_image() {
  local index="$1"
  tofu -chdir="$INFRA" state show "hcloud_server.server[${index}]" |
    sed -n 's/^[[:space:]]*image[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -n 1
}

[ -n "$TARGET_IMAGE" ] || die "TARGET_IMAGE is required; for example: make upgrade-os TARGET_IMAGE=ubuntu-26.04"
case "$TARGET_IMAGE" in
ubuntu-[0-9][0-9].[0-9][0-9]) ;;
*) die "TARGET_IMAGE must look like ubuntu-26.04" ;;
esac

case "$WAIT_TIMEOUT_SECONDS" in '' | *[!0-9]*) die "UPGRADE_OS_WAIT_TIMEOUT_SECONDS must be a non-negative integer" ;; esac
case "$BETWEEN_NODES_SECONDS" in '' | *[!0-9]*) die "UPGRADE_OS_BETWEEN_NODES_SECONDS must be a non-negative integer" ;; esac

for command in tofu kubectl jq ssh grep sed awk mktemp; do
  require_command "$command"
done

[ -f "$TFVARS" ] || die "missing ${TFVARS}; copy terraform.tfvars.example and fill it in first"
[ -f "$KUBECONFIG" ] || die "missing kubeconfig at ${KUBECONFIG}; deploy the cluster before upgrading it"

SERVER_NODES_JSON="$(tofu -chdir="$INFRA" output -json server_nodes 2>/dev/null)" ||
  die "cannot read OpenTofu server_nodes output; deploy stack 01 first"
SERVER_COUNT="$(printf '%s' "$SERVER_NODES_JSON" | jq 'length')"
[ "$SERVER_COUNT" -ge 3 ] || die "expected at least three OpenTofu-managed server nodes"

STATE_SERVER_COUNT="$(tofu -chdir="$INFRA" state list |
  grep -Ec '^hcloud_server\.server\[[0-9]+\]$' || true)"
[ "$STATE_SERVER_COUNT" -eq "$SERVER_COUNT" ] ||
  die "OpenTofu state has ${STATE_SERVER_COUNT} servers but the output has ${SERVER_COUNT}"

SSH_KEY="$(tofu -chdir="$INFRA" output -raw ssh_private_key_path 2>/dev/null)" ||
  die "cannot read ssh_private_key_path from OpenTofu"
[ -f "$SSH_KEY" ] || die "SSH private key not found: ${SSH_KEY}"

kubectl version --request-timeout=10s >/dev/null 2>&1 ||
  die "cannot reach the Kubernetes API with ${KUBECONFIG}"

FIRST_IP="$(printf '%s' "$SERVER_NODES_JSON" | jq -r '.[0].public_ip')"
check_cluster_health "$SERVER_COUNT" "$FIRST_IP"

PERSISTENT_LOCAL_VOLUMES="$(kubectl get pv -o json |
  jq -r '.items[] | select(.spec.storageClassName == "local-path" and .status.phase == "Bound") | .metadata.name')"
[ -z "$PERSISTENT_LOCAL_VOLUMES" ] || die "bound local-path volumes would be lost during node replacement: ${PERSISTENT_LOCAL_VOLUMES//$'\n'/, }"

NEEDS_REPLACEMENT=0
for ((index = SERVER_COUNT - 1; index >= 0; index--)); do
  if [ "$(current_image "$index")" != "$TARGET_IMAGE" ]; then
    NEEDS_REPLACEMENT=1
  fi
done

if [ "$NEEDS_REPLACEMENT" -eq 0 ]; then
  persist_target_image
  log "all ${SERVER_COUNT} nodes already use ${TARGET_IMAGE}; nothing to replace"
  exit 0
fi

log "validating the target image and checking for unrelated OpenTofu changes"
set +e
tofu -chdir="$INFRA" plan \
  -input=false \
  -detailed-exitcode \
  -var="os_image=${TARGET_IMAGE}"
PLAN_STATUS=$?
set -e
case "$PLAN_STATUS" in
0) ;;
1) die "OpenTofu could not plan the OS replacement" ;;
2) die "OpenTofu has unrelated pending changes; apply or resolve them before upgrading the OS" ;;
*) die "OpenTofu plan returned unexpected exit status ${PLAN_STATUS}" ;;
esac

persist_target_image
log "persisted os_image = \"${TARGET_IMAGE}\" in ${TFVARS}"

SNAPSHOT_NAME="before-os-${TARGET_IMAGE#ubuntu-}-$(date +%Y%m%d-%H%M%S)"
"${ROOT}/scripts/etcd-snapshot.sh" save "$SNAPSHOT_NAME"
"${ROOT}/scripts/etcd-snapshot.sh" list | grep -F "$SNAPSHOT_NAME" >/dev/null ||
  die "snapshot ${SNAPSHOT_NAME} was not visible after it was created"

for ((index = SERVER_COUNT - 1; index >= 0; index--)); do
  SERVER_NODES_JSON="$(tofu -chdir="$INFRA" output -json server_nodes)"
  NODE="$(printf '%s' "$SERVER_NODES_JSON" | jq -r ".[${index}].name")"
  OLD_IP="$(printf '%s' "$SERVER_NODES_JSON" | jq -r ".[${index}].public_ip")"
  OLD_IMAGE="$(current_image "$index")"

  if [ "$OLD_IMAGE" = "$TARGET_IMAGE" ]; then
    log "${NODE} already uses ${TARGET_IMAGE}; skipping"
    continue
  fi

  log "replacing ${NODE}: ${OLD_IMAGE} -> ${TARGET_IMAGE}"
  kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data --timeout=300s

  # Remove the etcd member and Node identity before reusing the hostname.
  kubectl annotate node "$NODE" etcd.k3s.cattle.io/remove=true --overwrite
  wait_for_etcd_removal "$NODE" ||
    die "timed out waiting for K3s to remove ${NODE} from embedded etcd"

  ssh_node "$OLD_IP" 'systemctl stop k3s || true; /usr/local/bin/k3s-killall.sh || true'
  kubectl delete node "$NODE" --wait=true --timeout=60s

  tofu -chdir="$INFRA" apply \
    -replace="hcloud_server.server[${index}]" \
    -auto-approve

  SERVER_NODES_JSON="$(tofu -chdir="$INFRA" output -json server_nodes)"
  NEW_IP="$(printf '%s' "$SERVER_NODES_JSON" | jq -r ".[${index}].public_ip")"

  wait_for_new_node "$NODE" ||
    die "${NODE} did not return Ready with the etcd role; it remains cordoned if it registered"

  ACTUAL_VERSION="$(ssh_node "$NEW_IP" '. /etc/os-release; printf "%s" "$VERSION_ID"')"
  EXPECTED_VERSION="${TARGET_IMAGE#ubuntu-}"
  [ "$ACTUAL_VERSION" = "$EXPECTED_VERSION" ] ||
    die "${NODE} reports Ubuntu ${ACTUAL_VERSION}, expected ${EXPECTED_VERSION}"

  check_cluster_health "$SERVER_COUNT" "$NEW_IP"
  kubectl uncordon "$NODE"
  log "${NODE} is healthy on ${TARGET_IMAGE}"

  if [ "$index" -gt 0 ] && [ "$BETWEEN_NODES_SECONDS" -gt 0 ]; then
    log "waiting ${BETWEEN_NODES_SECONDS}s before the next node"
    sleep "$BETWEEN_NODES_SECONDS"
  fi
done

log "OS replacement complete: all ${SERVER_COUNT} nodes use ${TARGET_IMAGE}"

#!/usr/bin/env bash
# Retire custom nodes while they are reachable, then apply the reviewed VM plan.
set +x
set -euo pipefail
umask 077

fail() { echo "ERROR: $*" >&2; exit 1; }
[ "$#" -eq 1 ] || fail 'usage: rke2-apply.sh <cluster-dir>'
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_DIR="$(cd "$1" && pwd)"
NAME="$(basename "$CLUSTER_DIR")"
[[ "$NAME" =~ ^[a-z0-9][-a-z0-9]*$ ]] || fail 'Invalid cluster directory name'
for tool in tofu kubectl jq; do command -v "$tool" >/dev/null || fail "$tool is required"; done
ETCD_HEALTH_ATTEMPTS="${RKE2_ETCD_HEALTH_ATTEMPTS:-60}"
[[ "$ETCD_HEALTH_ATTEMPTS" =~ ^[1-9][0-9]*$ ]] && [ "$ETCD_HEALTH_ATTEMPTS" -le 60 ] ||
  fail 'RKE2_ETCD_HEALTH_ATTEMPTS must be an integer from 1 to 60'
WORK="$(mktemp -d)"
LOCK="$CLUSTER_DIR/.rke2-apply-lock"
LOCKED=false
cleanup() {
  rm -rf "$WORK"
  if [ "$LOCKED" = true ]; then rmdir "$LOCK"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$LOCK" 2>/dev/null || fail 'Another apply is running, or .rke2-apply-lock remains from an interrupted process; inspect it before retrying'
LOCKED=true

tofu -chdir="$CLUSTER_DIR" state pull >"$WORK/state-before" 2>"$WORK/error" || :
tofu -chdir="$CLUSTER_DIR" plan -out="$WORK/plan"
tofu -chdir="$CLUSTER_DIR" show -json "$WORK/plan" >"$WORK/plan.json"
jq '[.resource_changes[]? | select(.mode == "managed" and .type == "hcloud_server" and
  (.change.actions | index("delete")) != null)]' "$WORK/plan.json" >"$WORK/deletions"
if [ "$(jq length "$WORK/deletions")" -gt 0 ]; then
  # Replacement and mixed grow/shrink plans need new capacity before retirement.
  jq -e --arg name "$NAME" '
    all(.[]; .address | test("^module\\.rke2\\.hcloud_server\\.node\\[\"(server|worker)-[0-9]+\"\\]$")) and
    all(.[]; .change.actions == ["delete"] and
      (.change.before.name | test("^" + $name + "-(server|worker)-[0-9]+$")) and
      (.change.before.id | tostring | test("^[0-9]+$")))' "$WORK/deletions" >/dev/null ||
    fail 'Only count reductions of this custom cluster are supported; stage VM replacements separately'
  jq -e 'all(.resource_changes[]? | select(.mode == "managed" and .type == "hcloud_server");
    (.change.actions | index("create")) == null)' "$WORK/plan.json" >/dev/null ||
    fail 'Add the new nodes in a separate apply before reducing existing node counts'
  jq -e 'all(.resource_changes[]? | select(.mode == "managed" and
    .type != "hcloud_server" and .type != "hcloud_load_balancer_target" and .type != "terraform_data");
    .change.actions == ["no-op"] or .change.actions == ["read"])' "$WORK/plan.json" >/dev/null ||
    fail 'Apply other infrastructure or Rancher configuration changes separately from node retirement'
  jq -e '.planned_values.outputs.nodes.value | type == "object" and length > 0' "$WORK/plan.json" >/dev/null ||
    fail 'The saved plan has no known remaining node inventory'
  jq '[.planned_values.outputs.nodes.value[] | .name] | sort' "$WORK/plan.json" >"$WORK/desired"
  jq --slurpfile desired "$WORK/desired" '[.resource_changes[]? | .change.after.name as $node |
    select(.mode == "managed" and .type == "hcloud_server" and ($desired[0] | index($node)) != null) |
    {name:.change.after.name,id:(.change.after.id|tostring)}]' \
    "$WORK/plan.json" >"$WORK/remaining-vms"
  jq -e --slurpfile desired "$WORK/desired" 'length == ($desired[0] | length) and
    all(.[]; .id | test("^[0-9]+$"))' "$WORK/remaining-vms" >/dev/null || fail 'The remaining VM identities must be known in the saved plan'
  jq -e --arg name "$NAME" 'all(.[]; test("^" + $name + "-(server|worker)-[0-9]+$")) and
    ([.[] | select(test("-server-[0-9]+$"))] | length) >= 3' "$WORK/desired" >/dev/null ||
    fail 'Retirement requires at least three remaining server nodes'
  jq -e --slurpfile desired "$WORK/desired" 'all(.[]; .change.before.name as $node |
    ($desired[0] | index($node)) == null)' "$WORK/deletions" >/dev/null || fail 'A retiring node is still desired by the saved plan'
  echo 'Before deleting VMs, this apply will migrate Longhorn data and retire these nodes through Rancher:'
  jq -r '.[].change.before.name' "$WORK/deletions"
fi

# Saved-plan apply does not prompt; preserve approval before any cluster mutation.
printf 'Type yes to execute this plan (including any node retirement): '
IFS= read -r answer || fail 'Apply cancelled; no retirement was started'
[ "$answer" = yes ] || fail 'Apply cancelled; no retirement was started'

if [ "$(jq length "$WORK/deletions")" -eq 0 ]; then
  tofu -chdir="$CLUSTER_DIR" apply "$WORK/plan"
  exit 0
fi

check_state() {
  tofu -chdir="$CLUSTER_DIR" state pull >"$WORK/state-current" 2>"$WORK/error" || fail 'Cannot check state freshness; VMs are preserved'
  jq -e --slurpfile before "$WORK/state-before" '.serial == $before[0].serial and .lineage == $before[0].lineage and
    (.serial | type == "number") and (.lineage | type == "string")' "$WORK/state-current" >/dev/null ||
    fail 'OpenTofu state changed after planning; stop concurrent applies and rerun this command'
}
check_state

MANAGEMENT_CONFIG="$ROOT/stacks/01-infra/kubeconfig.yaml"
DOWNSTREAM_CONFIG="$CLUSTER_DIR/kubeconfig.yaml"
[ -f "$MANAGEMENT_CONFIG" ] && [ -f "$DOWNSTREAM_CONFIG" ] || fail 'Both management and downstream kubeconfigs are required for retirement'
CLUSTER_ID="$(jq -er '.planned_values.outputs.cluster_id.value' "$WORK/plan.json")"
CLUSTER_V1_ID="$(jq -er '.planned_values.outputs.cluster_v1_id.value' "$WORK/plan.json")"
[[ "$CLUSTER_ID" =~ ^[a-z0-9][-a-z0-9]*/[a-z0-9][-a-z0-9]*$ ]] || fail 'Invalid provisioning cluster ID'
NAMESPACE="${CLUSTER_ID%%/*}"
[ "${CLUSTER_ID#*/}" = "$NAME" ] || fail 'Saved plan belongs to a different cluster'
management() { kubectl --kubeconfig="$MANAGEMENT_CONFIG" --request-timeout=20s "$@"; }
downstream() { kubectl --kubeconfig="$DOWNSTREAM_CONFIG" --request-timeout=20s "$@"; }
read_management() { local file="$1"; shift; management "$@" >"$WORK/$file" 2>"$WORK/error" || fail "Cannot read Rancher $file; VMs have not been deleted"; }
read_downstream() { local file="$1"; shift; downstream "$@" >"$WORK/$file" 2>"$WORK/error" || fail "Cannot read downstream $file; VMs have not been deleted"; }
read_management provisioning get clusters.provisioning.cattle.io "$NAME" -n "$NAMESPACE" -o json
jq -e --arg id "$CLUSTER_V1_ID" '.status.clusterName == $id and .metadata.deletionTimestamp == null' "$WORK/provisioning" >/dev/null || fail 'Management kubeconfig does not match the saved plan'
read_management cluster get clusters.cluster.x-k8s.io "$NAME" -n "$NAMESPACE" -o json
CLUSTER_UID="$(jq -er '.metadata.uid | select(type == "string" and length > 0)' "$WORK/cluster")"
jq -e '.metadata.deletionTimestamp == null' "$WORK/cluster" >/dev/null || fail 'Cluster is deleting'
read_management machines get machines.cluster.x-k8s.io -n "$NAMESPACE" -l "cluster.x-k8s.io/cluster-name=$NAME" -o json
read_downstream nodes get nodes -o json
jq -e --slurpfile remaining "$WORK/remaining-vms" '.items as $nodes | all($remaining[0][]; . as $vm |
  any($nodes[]; .metadata.name == $vm.name and .spec.providerID == ("hcloud://" + $vm.id) and .metadata.deletionTimestamp == null and
    any(.status.conditions[]?; .type == "Ready" and .status == "True")))' "$WORK/nodes" >/dev/null || fail 'All remaining nodes must be Ready before retirement'

cat >"$WORK/machine.jq" <<'JQ'
def owned:
  .kind == "Machine" and .metadata.namespace == $namespace and
  .metadata.labels["cluster.x-k8s.io/cluster-name"] == $name and
  any(.metadata.ownerReferences[]?; .kind == "Cluster" and .name == $name and .uid == $cluster_uid) and
  .spec.infrastructureRef.kind == "CustomMachine" and
  (.spec.infrastructureRef.apiGroup // (.spec.infrastructureRef.apiVersion // "" | split("/")[0])) == "rke.cattle.io" and
  .spec.infrastructureRef.name == .metadata.name;
JQ
jq -r 'sort_by(.change.before.name)[] | [.change.before.name,(.change.before.id|tostring)] | @tsv' "$WORK/deletions" >"$WORK/retire"
# Validate every identity before cordoning or changing storage scheduling.
while IFS=$'\t' read -r node vm_id; do
  jq --arg node "$node" --arg name "$NAME" --arg namespace "$NAMESPACE" --arg cluster_uid "$CLUSTER_UID" \
    "$(cat "$WORK/machine.jq") [.items[] | select(owned and .status.nodeRef.name == \$node)]" "$WORK/machines" >"$WORK/$node-machine"
  jq -e 'length <= 1' "$WORK/$node-machine" >/dev/null || fail "Ambiguous Machine ownership for $node"
  if jq -e --arg node "$node" 'any(.items[]; .metadata.name == $node)' "$WORK/nodes" >/dev/null; then
    jq -e --arg node "$node" --arg id "$vm_id" 'any(.items[]; .metadata.name == $node and
      .spec.providerID == ("hcloud://" + $id) and
      any(.status.conditions[]?; .type == "Ready" and .status == "True"))' "$WORK/nodes" >/dev/null || fail "$node is not a Ready node belonging to the planned VM"
    jq -e 'length == 1' "$WORK/$node-machine" >/dev/null || fail "$node has no matching Rancher Machine"
    jq -r --arg node "$node" '.items[] | select(.metadata.name == $node) | .metadata.uid' "$WORK/nodes" >"$WORK/$node-uid"
  fi
  if [[ "$node" == "$NAME-server-"* ]] && [ "$(jq length "$WORK/$node-machine")" -eq 1 ]; then
    jq -e '.[0].metadata.labels["rke.cattle.io/etcd-role"] == "true" and
      (.[0].metadata.deletionTimestamp != null or
       .[0].metadata.annotations["pre-terminate.delete.hook.machine.cluster.x-k8s.io/rke-bootstrap-cleanup"] != null)' \
      "$WORK/$node-machine" >/dev/null || fail "$node is missing Rancher's etcd retirement hook"
  fi
done <"$WORK/retire"

SURVIVOR="$(jq -r '[.[] | select(test("-server-[0-9]+$"))][0]' "$WORK/desired")"
etcd() {
  downstream exec -n kube-system "etcd-$SURVIVOR" -c etcd -- etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
    --cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
    --key=/var/lib/rancher/rke2/server/tls/etcd/server-client.key "$@"
}
check_etcd() {
  local attempt
  for ((attempt = 1; attempt <= ETCD_HEALTH_ATTEMPTS; attempt++)); do
    if etcd member list -w json >"$WORK/members" 2>"$WORK/error" &&
      jq -e --slurpfile desired "$WORK/desired" '.members as $members |
        all($desired[0][] | select(test("-server-[0-9]+$")); . as $name |
          any($members[]; (.name == $name or (.name | startswith($name + "-"))) and .isLearner != true))' \
        "$WORK/members" >/dev/null &&
      etcd endpoint health --cluster -w json >"$WORK/health" 2>"$WORK/error" &&
      jq -e --slurpfile members "$WORK/members" 'length == ($members[0].members | length) and length >= 3 and
        all(.[]; .health == true)' "$WORK/health" >/dev/null; then
      return 0
    fi
    if [ "$attempt" -lt "$ETCD_HEALTH_ATTEMPTS" ]; then
      echo "Waiting for etcd membership and endpoints to converge ($attempt/$ETCD_HEALTH_ATTEMPTS)."
      sleep 5
    fi
  done
  fail 'etcd did not become healthy after five minutes; VMs are preserved'
}
check_etcd

read_downstream longhorn-crd get customresourcedefinitions nodes.longhorn.io --ignore-not-found -o name
LONGHORN=false
if [ -s "$WORK/longhorn-crd" ]; then
  LONGHORN=true
  read_downstream volumes get volumes.longhorn.io -n longhorn-system -o json
  jq -e 'all(.items[]; .status.robustness == "healthy")' "$WORK/volumes" >/dev/null || fail 'Longhorn volumes must be healthy before planned retirement'
fi

read_storage() {
  read_downstream longhorn get nodes.longhorn.io "$node" -n longhorn-system --ignore-not-found -o json
  for resource in replicas engines volumes backingimages; do
    read_downstream "$resource" get "$resource.longhorn.io" -n longhorn-system -o json
  done
}
storage_empty() {
  jq -e --arg node "$node" 'all(.items[]; .spec.nodeID != $node)' "$WORK/replicas" >/dev/null &&
  { [ ! -s "$WORK/longhorn" ] || jq -e 'all(.status.diskStatus[]?;
      (.scheduledReplica // {} | length) == 0 and (.scheduledBackingImage // {} | length) == 0)' "$WORK/longhorn" >/dev/null; } &&
  { [ ! -s "$WORK/longhorn" ] || jq -e --slurpfile node "$WORK/longhorn" '
      [$node[0].status.diskStatus[]?.diskUUID | select(. != null)] as $disks |
      all(.items[]; ((.spec.diskFileSpecMap // {} | keys) + (.spec.disks // {} | keys)) as $refs |
        all($refs[]; . as $disk | ($disks | index($disk)) == null))' "$WORK/backingimages" >/dev/null; }
}
storage_detached() {
  jq -e --arg node "$node" 'all(.items[]; .spec.nodeID != $node)' "$WORK/engines" >/dev/null &&
  jq -e --arg node "$node" 'all(.items[]; .spec.nodeID != $node and
    .status.currentNodeID != $node and .status.pendingNodeID != $node)' "$WORK/volumes" >/dev/null
}

# Exclude every retiring node so eviction cannot move data to the next victim.
while IFS=$'\t' read -r node vm_id; do
  read_downstream current-node get node "$node" --ignore-not-found -o json
  [ -s "$WORK/current-node" ] || continue
  [ -f "$WORK/$node-uid" ] || fail "$node appeared during retirement"
  jq -e --arg id "$vm_id" --arg uid "$(cat "$WORK/$node-uid")" '.spec.providerID == ("hcloud://" + $id) and
    .metadata.uid == $uid' "$WORK/current-node" >/dev/null || fail "$node changed identity"
  jq '{metadata:{uid:.metadata.uid,resourceVersion:.metadata.resourceVersion},spec:{unschedulable:true}}' "$WORK/current-node" >"$WORK/patch"
  downstream patch node "$node" --type=merge --patch-file="$WORK/patch" >"$WORK/patched" 2>"$WORK/error" || fail "Cannot cordon $node; VMs are preserved"
done <"$WORK/retire"
if [ "$LONGHORN" = true ]; then
  while IFS=$'\t' read -r node vm_id; do
    read_downstream longhorn get nodes.longhorn.io "$node" -n longhorn-system --ignore-not-found -o json
    [ -s "$WORK/longhorn" ] || continue
    jq -r '.metadata.uid' "$WORK/longhorn" >"$WORK/$node-longhorn-uid"
    jq '{metadata:{uid:.metadata.uid,resourceVersion:.metadata.resourceVersion},
      spec:{allowScheduling:false,disks:(.spec.disks | with_entries(.value.allowScheduling=false))}}' "$WORK/longhorn" >"$WORK/patch"
    downstream patch nodes.longhorn.io "$node" -n longhorn-system --type=merge --patch-file="$WORK/patch" \
      >"$WORK/patched" 2>"$WORK/error" || fail "Cannot disable Longhorn scheduling on $node; VMs are preserved"
  done <"$WORK/retire"
fi

while IFS=$'\t' read -r node vm_id; do
  check_state
  echo "Retiring $node before deleting its VM."
  if [ "$LONGHORN" = true ]; then
    read_storage
    if [ -s "$WORK/longhorn" ]; then
      [ -f "$WORK/$node-longhorn-uid" ] || fail "Longhorn Node $node appeared during retirement"
      jq -e --arg uid "$(cat "$WORK/$node-longhorn-uid")" '.metadata.uid == $uid and .spec.allowScheduling == false' \
        "$WORK/longhorn" >/dev/null || fail "Longhorn Node $node changed identity or scheduling"
      jq '{metadata:{uid:.metadata.uid,resourceVersion:.metadata.resourceVersion},spec:{evictionRequested:true}}' "$WORK/longhorn" >"$WORK/patch"
      downstream patch nodes.longhorn.io "$node" -n longhorn-system --type=merge --patch-file="$WORK/patch" \
        >"$WORK/patched" 2>"$WORK/error" || fail "Cannot request Longhorn eviction for $node; VMs are preserved"
    fi
    deadline=$((SECONDS + 1800))
    while ! storage_empty; do
      [ "$SECONDS" -lt "$deadline" ] || fail "Longhorn evacuation timed out for $node; VMs are preserved, inspect space and scheduling then retry"
      echo "Waiting for Longhorn replicas and backing images to leave $node."
      sleep 5
      read_storage
    done
    jq -e 'all(.items[]; .status.robustness == "healthy")' "$WORK/volumes" >/dev/null || fail 'Longhorn is not healthy after evacuation; VMs are preserved'
  fi

  read_downstream current-node get node "$node" --ignore-not-found -o json
  if [ -s "$WORK/current-node" ]; then
    [ -f "$WORK/$node-uid" ] || fail "$node appeared during retirement"
    jq -e --arg id "$vm_id" --arg uid "$(cat "$WORK/$node-uid")" '.spec.providerID == ("hcloud://" + $id) and
      .metadata.uid == $uid and .spec.unschedulable == true' "$WORK/current-node" >/dev/null || fail "$node changed or was uncordoned"
    # Honour PDBs and protect emptyDir / unmanaged Pods instead of forcing eviction.
    downstream drain "$node" --ignore-daemonsets --timeout=30m >"$WORK/drain" 2>"$WORK/error" ||
      fail "Drain failed for $node (check PDBs, emptyDir and unmanaged Pods); VMs are preserved"
  fi
  if [ "$LONGHORN" = true ]; then
    deadline=$((SECONDS + 600))
    while :; do
      read_storage
      if storage_empty && storage_detached; then break; fi
      [ "$SECONDS" -lt "$deadline" ] || fail "Longhorn storage is still using $node; VMs are preserved"
      echo "Waiting for volumes and engines to detach from $node."
      sleep 5
    done
  fi
  read_downstream attachments get volumeattachments.storage.k8s.io -o json
  jq -e --arg node "$node" 'all(.items[]; .spec.nodeName != $node)' "$WORK/attachments" >/dev/null || fail "$node still has CSI VolumeAttachments; VMs are preserved"
  check_etcd
  check_state
  machine="$(jq -r '.[0].metadata.name // empty' "$WORK/$node-machine")"
  if [ -n "$machine" ]; then
    read_management current-machine get machines.cluster.x-k8s.io "$machine" -n "$NAMESPACE" --ignore-not-found -o json
    if [ -s "$WORK/current-machine" ]; then
      jq -e --arg name "$NAME" --arg namespace "$NAMESPACE" --arg cluster_uid "$CLUSTER_UID" \
        --arg node "$node" --arg uid "$(jq -r '.[0].metadata.uid' "$WORK/$node-machine")" \
        "$(cat "$WORK/machine.jq") owned and .metadata.uid == \$uid and .status.nodeRef.name == \$node" \
        "$WORK/current-machine" >/dev/null || fail "$machine changed identity; VMs are preserved"
      if [[ "$node" == "$NAME-server-"* ]]; then
        jq -e '.metadata.deletionTimestamp != null or
          .metadata.annotations["pre-terminate.delete.hook.machine.cluster.x-k8s.io/rke-bootstrap-cleanup"] != null' \
          "$WORK/current-machine" >/dev/null || fail "$node lost its etcd retirement hook; VMs are preserved"
      fi
      if jq -e '.metadata.deletionTimestamp == null' "$WORK/current-machine" >/dev/null; then
        jq '{apiVersion:"v1",kind:"DeleteOptions",preconditions:{uid:.metadata.uid,resourceVersion:.metadata.resourceVersion}}' \
          "$WORK/current-machine" >"$WORK/delete-options"
        version="$(jq -er '.apiVersion | select(test("^cluster\\.x-k8s\\.io/v[0-9]+(alpha[0-9]+|beta[0-9]+)?$"))' "$WORK/current-machine")"
        management delete --raw "/apis/$version/namespaces/$NAMESPACE/machines/$machine" -f "$WORK/delete-options" \
          >"$WORK/deleted" 2>"$WORK/error" || fail "Cannot retire $machine through Rancher; VMs are preserved"
        echo "Requested Rancher retirement for $node."
      fi
      management wait --for=delete "machines.cluster.x-k8s.io/$machine" -n "$NAMESPACE" --timeout=600s \
        >"$WORK/wait" 2>"$WORK/error" || fail "$machine retirement is pending; VMs are preserved, retry without removing finalizers"
    fi
  fi
  downstream wait --for=delete "node/$node" --timeout=600s >"$WORK/wait" 2>"$WORK/error" || fail "$node still exists; VMs are preserved"
  check_etcd
  jq -e --arg node "$node" 'all(.members[]; .name != $node and (.name | startswith($node + "-") | not))' \
    "$WORK/members" >/dev/null || fail "$node remains an etcd member; VMs are preserved"
  echo "Retired $node; etcd remains healthy."
done <"$WORK/retire"

# Recheck all retirees immediately before authorising cloud deletion.
read_downstream nodes get nodes -o json
jq -e --slurpfile desired "$WORK/desired" --slurpfile deletions "$WORK/deletions" '.items as $nodes |
  all($desired[0][]; . as $name | any($nodes[]; .metadata.name == $name and
    any(.status.conditions[]?; .type == "Ready" and .status == "True"))) and
  all($deletions[0][]; .change.before.name as $name | all($nodes[]; .metadata.name != $name))' "$WORK/nodes" >/dev/null || fail 'Node inventory changed during retirement; VMs are preserved'
check_etcd
if [ "$LONGHORN" = true ]; then
  while IFS=$'\t' read -r node vm_id; do
    read_storage
    storage_empty && storage_detached || fail "Storage reappeared on $node; VMs are preserved"
    jq -e 'all(.items[]; .status.robustness == "healthy")' "$WORK/volumes" >/dev/null || fail 'Longhorn became unhealthy; VMs are preserved'
  done <"$WORK/retire"
fi
check_state
tofu -chdir="$CLUSTER_DIR" apply "$WORK/plan"

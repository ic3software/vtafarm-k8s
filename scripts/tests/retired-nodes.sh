#!/usr/bin/env bash
# Exercise the inline OpenTofu provisioner against fake Kubernetes APIs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export TEST_DIR
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/bodies"
export PATH="$TEST_DIR/bin:$PATH"
touch "$TEST_DIR/management" "$TEST_DIR/downstream"
fail() { echo "FAIL: $*" >&2; exit 1; }

export CLUSTER_NAME=rke2-test CLUSTER_ID=fleet-default/rke2-test CLUSTER_V1_ID=c-test
export MANAGEMENT_CONFIG="$TEST_DIR/management" DOWNSTREAM_CONFIG="$TEST_DIR/downstream"
export DESIRED_NODES='["rke2-test-server-1","rke2-test-server-2","rke2-test-server-3"]'
awk '/^[[:space:]]*SHELL$/ {exit} /command = <<-SHELL/ {inside=1;next} inside {sub(/^      /, "");print}' \
  "$ROOT/modules/rke2-custom-cluster/retired-nodes.tf" >"$TEST_DIR/command"
jq -n '{metadata:{uid:"cluster-uid"}}' >"$TEST_DIR/cluster"
jq -n '{status:{clusterName:"c-test"}}' >"$TEST_DIR/provisioning"
jq -n '{items:[range(1;4) | {metadata:{name:("rke2-test-server-" + tostring)},status:{conditions:[{type:"Ready",status:"True"}]}}]}' >"$TEST_DIR/nodes-base"
jq -n '{items:[{apiVersion:"longhorn.io/v1beta2",kind:"Node",
  metadata:{name:"rke2-test-worker-1",namespace:"longhorn-system",uid:"rke2-test-worker-1-uid",resourceVersion:"42"},
  spec:{allowScheduling:true,disks:{disk:{allowScheduling:true,path:"/var/lib/longhorn"}}},
  status:{conditions:[{type:"Ready",status:"False",reason:"KubernetesNodeGone"}],
    diskStatus:{disk:{diskUUID:"disk-uuid",scheduledReplica:{},scheduledBackingImage:{}}}}}]}' >"$TEST_DIR/longhorn-base"
jq -n '
  def machine($id; $node): {
    apiVersion:"cluster.x-k8s.io/v1beta2",kind:"Machine",
    metadata:{name:$id,namespace:"fleet-default",uid:($id + "-uid"),resourceVersion:"42",
      labels:{"cluster.x-k8s.io/cluster-name":"rke2-test"},
      ownerReferences:[{kind:"Cluster",name:"rke2-test",uid:"cluster-uid"}]},
    spec:{infrastructureRef:{apiGroup:"rke.cattle.io",kind:"CustomMachine",name:$id}},
    status:{nodeRef:{name:$node},conditions:[{type:"NodeHealthy",status:"False",reason:"NodeDeleted"}]}};
  {items:[
    machine("custom-worker-1";"rke2-test-worker-1"),
    machine("custom-worker-2";"rke2-test-worker-2"),
    machine("custom-desired";"rke2-test-server-1"),
    (machine("custom-other-owner";"rke2-test-worker-3") | .metadata.ownerReferences[0].uid="other-uid"),
    (machine("custom-other-cluster";"rke2-test-worker-4") | .metadata.labels["cluster.x-k8s.io/cluster-name"]="other"),
    (machine("custom-other-infra";"rke2-test-worker-5") | .spec.infrastructureRef.kind="OtherMachine"),
    (machine("custom-joining";"rke2-test-worker-6") | del(.status.nodeRef)),
    machine("custom-other-name";"other-worker-1")
  ]}' >"$TEST_DIR/machines-base"

cat >"$TEST_DIR/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
config=''; args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --kubeconfig=*) config="${1#*=}";;
    --request-timeout=*) ;;
    *) args+=("$1");;
  esac
  shift
done
set -- "${args[@]}"
printf '%s %s\n' "$config" "$*" >>"$TEST_DIR/calls"
case "$1 $2" in
  'get clusters.provisioning.cattle.io') cat "$TEST_DIR/provisioning";;
  'get clusters.cluster.x-k8s.io') cat "$TEST_DIR/cluster";;
  'get machines.cluster.x-k8s.io')
    if [ "$3" = -n ]; then
      cat "$TEST_DIR/machines"
    else
      jq --arg name "$3" '.items[] | select(.metadata.name == $name)' "$TEST_DIR/machines" >"$TEST_DIR/current"
      if [ "$TEST_MODE" = changed ]; then
        jq '.metadata.uid="recreated-uid"' "$TEST_DIR/current"
      else
        cat "$TEST_DIR/current"
      fi
    fi;;
  'get nodes')
    [ "$config" = "$TEST_DIR/downstream" ] || exit 1
    [ "$TEST_MODE" != unavailable ] || exit 1
    if [ "$TEST_MODE" = reappeared ] && [ -f "$TEST_DIR/probed" ]; then
      jq '.items += [{metadata:{name:"rke2-test-worker-1"}}]' "$TEST_DIR/nodes"
    else
      cat "$TEST_DIR/nodes"
    fi
    touch "$TEST_DIR/probed";;
  'get customresourcedefinitions')
    case "$TEST_MODE" in longhorn*) echo customresourcedefinition.apiextensions.k8s.io/nodes.longhorn.io;; esac;;
  'get nodes.longhorn.io')
    [ "$config" = "$TEST_DIR/downstream" ] || exit 1
    if [ "$3" = -n ]; then
      cat "$TEST_DIR/longhorn"
    else
      jq --arg name "$3" '.items[] | select(.metadata.name == $name)' "$TEST_DIR/longhorn"
    fi;;
  'get replicas.longhorn.io'|'get engines.longhorn.io'|'get volumes.longhorn.io'|'get backingimages.longhorn.io')
    [ "$config" = "$TEST_DIR/downstream" ] || exit 1
    cat "$TEST_DIR/$2";;
  'patch nodes.longhorn.io')
    [ "$config" = "$TEST_DIR/downstream" ] || exit 1
    patch="${7#--patch-file=}"
    jq -e '.metadata.uid == "rke2-test-worker-1-uid" and .metadata.resourceVersion == "42" and
      .spec.allowScheduling == false and all(.spec.disks[]; .allowScheduling == false)' "$patch" >/dev/null || exit 1
    jq --slurpfile patch "$patch" '.items[0] *= $patch[0]' "$TEST_DIR/longhorn" >"$TEST_DIR/longhorn-next"
    mv "$TEST_DIR/longhorn-next" "$TEST_DIR/longhorn"
    if [ "$TEST_MODE" = longhorn-race ]; then
      jq -n '{items:[{spec:{nodeID:"rke2-test-worker-1"}}]}' >"$TEST_DIR/replicas.longhorn.io"
    fi
    echo "PATCH $3" >>"$TEST_DIR/patches";;
  'delete --raw')
    case "$3" in
      */longhorn-system/nodes/*) [ "$config" = "$TEST_DIR/downstream" ] || exit 1;;
      *) [ "$config" = "$TEST_DIR/management" ] || exit 1;;
    esac
    machine="${3##*/}"
    [ "$4" = -f ] || exit 1
    jq -e --arg uid "$machine-uid" '.kind == "DeleteOptions" and .preconditions.uid == $uid and .preconditions.resourceVersion == "42"' "$5" >/dev/null || exit 1
    cp "$5" "$TEST_DIR/bodies/$machine"
    echo "DELETE $machine" >>"$TEST_DIR/deletions"
    [ "$TEST_MODE" != conflict ] || exit 1
    echo '{}' ;;
  'wait --for=delete')
    [ "$TEST_MODE" != pending ] || exit 1;;
  *) exit 1;;
esac
MOCK
cat >"$TEST_DIR/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [ "$TEST_MODE" = converging ]; then
  cp "$TEST_DIR/nodes-base" "$TEST_DIR/nodes"
  cp "$TEST_DIR/machines-base" "$TEST_DIR/machines"
  exit 0
fi
exit 1
MOCK
chmod +x "$TEST_DIR/bin/"*
reset_case() {
  export TEST_MODE="$1"
  cp "$TEST_DIR/machines-base" "$TEST_DIR/machines"
  cp "$TEST_DIR/nodes-base" "$TEST_DIR/nodes"
  cp "$TEST_DIR/longhorn-base" "$TEST_DIR/longhorn"
  for resource in replicas engines volumes backingimages; do
    echo '{"items":[]}' >"$TEST_DIR/$resource.longhorn.io"
  done
  : >"$TEST_DIR/calls"
  : >"$TEST_DIR/deletions"
  : >"$TEST_DIR/patches"
  rm -f "$TEST_DIR/probed"
}
run() {
  export DOWNSTREAM_CONFIG="${2:-$TEST_DIR/downstream}"
  bash "$TEST_DIR/command" >"$TEST_DIR/log" 2>&1
}
assert_no_deletes() { [ ! -s "$TEST_DIR/deletions" ] || fail 'deleted a protected Machine'; }
expect_failure() {
  if run cleanup; then fail "$TEST_MODE unexpectedly succeeded"; fi
  assert_no_deletes
}

reset_case ok
run cleanup || { cat "$TEST_DIR/log"; fail cleanup; }
printf 'DELETE custom-worker-1\nDELETE custom-worker-2\n' >"$TEST_DIR/expected"
cmp -s "$TEST_DIR/expected" "$TEST_DIR/deletions" || fail 'cleanup crossed cluster, state or infrastructure boundaries'
echo 'PASS: cleanup deletes exactly the two retired workers with UID/resource-version preconditions'

reset_case ok
jq '.items += [{metadata:{name:"rke2-test-worker-1"},status:{conditions:[{type:"Ready",status:"False"}]}}]' \
  "$TEST_DIR/nodes-base" >"$TEST_DIR/nodes"
expect_failure
echo 'PASS: a live NotReady node is preserved despite a stale NodeDeleted condition'

for mode in unavailable changed reappeared; do
  reset_case "$mode"
  expect_failure
done
echo 'PASS: API failures, recreated Machines and reappearing nodes stop deletion'

reset_case ok
jq '.items |= .[1:]' "$TEST_DIR/nodes-base" >"$TEST_DIR/nodes"
expect_failure
reset_case ok
jq '.items[0].status.conditions[0].status="False"' "$TEST_DIR/nodes-base" >"$TEST_DIR/nodes"
expect_failure
echo 'PASS: missing or NotReady applied nodes block cleanup'

reset_case ok
jq '.status.clusterName="c-other"' "$TEST_DIR/provisioning" >"$TEST_DIR/provisioning-next"
mv "$TEST_DIR/provisioning-next" "$TEST_DIR/provisioning"
expect_failure
jq -n '{status:{clusterName:"c-test"}}' >"$TEST_DIR/provisioning"
echo 'PASS: a management cluster inconsistent with OpenTofu state is rejected'

for mode in conflict pending; do
  reset_case "$mode"
  if run cleanup; then fail "$mode unexpectedly succeeded"; fi
  [ "$(wc -l <"$TEST_DIR/deletions" | tr -d ' ')" -eq 1 ] || fail 'continued deleting after an API or finalizer failure'
  if grep -Eq -- '--force|patch|finalizers' "$TEST_DIR/calls"; then fail 'bypassed normal deletion'; fi
done
echo 'PASS: deletion conflicts and pending finalizers fail without forcing or continuing'

reset_case ok
jq '.items |= map(select(.metadata.name != "custom-worker-1" and .metadata.name != "custom-worker-2"))' \
  "$TEST_DIR/machines-base" >"$TEST_DIR/machines"
run cleanup "$TEST_DIR/missing-config" || { cat "$TEST_DIR/log"; fail 'first-deployment cleanup'; }
assert_no_deletes
echo 'PASS: a first deployment without retired Machines needs no downstream kubeconfig'

reset_case converging
jq '.items += [{metadata:{name:"rke2-test-worker-1"},status:{conditions:[{type:"Ready",status:"False"}]}}]' \
  "$TEST_DIR/nodes-base" >"$TEST_DIR/nodes"
jq '(.items[] | select(.metadata.name == "custom-worker-1").status.conditions[0].reason)="WaitingForNode"' \
  "$TEST_DIR/machines-base" >"$TEST_DIR/machines"
run cleanup || { cat "$TEST_DIR/log"; fail 'asynchronous retirement'; }
printf 'DELETE custom-worker-1\nDELETE custom-worker-2\n' >"$TEST_DIR/expected"
cmp -s "$TEST_DIR/expected" "$TEST_DIR/deletions" || fail 'cleanup missed nodes after controllers converged'
echo 'PASS: cleanup waits for node removal and Rancher condition convergence'

reset_case ok
jq '(.items[0] | .metadata.name="custom-server-4" | .metadata.uid="custom-server-4-uid" |
  .spec.infrastructureRef.name="custom-server-4" | .status.nodeRef.name="rke2-test-server-4"),
  (.items[1] | .metadata.name="custom-server-5" | .metadata.uid="custom-server-5-uid" |
  .spec.infrastructureRef.name="custom-server-5" | .status.nodeRef.name="rke2-test-server-5")' \
  "$TEST_DIR/machines-base" | jq -s '{items:.}' >"$TEST_DIR/machines"
run cleanup || { cat "$TEST_DIR/log"; fail 'server scale-down'; }
printf 'DELETE custom-server-4\nDELETE custom-server-5\n' >"$TEST_DIR/expected"
cmp -s "$TEST_DIR/expected" "$TEST_DIR/deletions" || fail 'server scale-down left retired Machines'
echo 'PASS: five-to-three server scale-down removes exactly server-4 and server-5 Machines'

reset_case longhorn
echo '{"items":[]}' >"$TEST_DIR/machines"
run cleanup || { cat "$TEST_DIR/log"; fail 'Longhorn cleanup after manual Rancher deletion'; }
grep -qx 'DELETE rke2-test-worker-1' "$TEST_DIR/deletions" || fail 'retired Longhorn Node was not deleted'
grep -qx 'PATCH rke2-test-worker-1' "$TEST_DIR/patches" || fail 'Longhorn scheduling was not disabled'
echo 'PASS: Longhorn cleanup works after the Rancher Machine has already been removed'

for resource in replicas engines volumes backingimages; do
  reset_case "longhorn-$resource"
  echo '{"items":[]}' >"$TEST_DIR/machines"
  case "$resource" in
    replicas|engines) jq -n '{items:[{spec:{nodeID:"rke2-test-worker-1"}}]}' >"$TEST_DIR/$resource.longhorn.io";;
    volumes) jq -n '{items:[{status:{currentNodeID:"rke2-test-worker-1"}}]}' >"$TEST_DIR/$resource.longhorn.io";;
    backingimages) jq -n '{items:[{spec:{diskFileSpecMap:{"disk-uuid":{}}}}]}' >"$TEST_DIR/$resource.longhorn.io";;
  esac
  expect_failure
  [ ! -s "$TEST_DIR/patches" ] || fail 'changed a Longhorn Node with storage dependencies'
done
echo 'PASS: replica, engine, volume and backing-image references block Longhorn cleanup'

reset_case longhorn-scheduled
echo '{"items":[]}' >"$TEST_DIR/machines"
jq '.items[0].status.diskStatus.disk.scheduledReplica={"replica":1}' "$TEST_DIR/longhorn-base" >"$TEST_DIR/longhorn"
expect_failure
echo 'PASS: scheduled disk data blocks Longhorn cleanup'

reset_case longhorn-race
echo '{"items":[]}' >"$TEST_DIR/machines"
expect_failure
grep -qx 'PATCH rke2-test-worker-1' "$TEST_DIR/patches" || fail 'did not exercise storage appearing after scheduling was disabled'
echo 'PASS: storage dependencies are rechecked after disabling scheduling'

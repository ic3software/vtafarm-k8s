# Rancher and Longhorn metadata are outside the VM provider's lifecycle.
resource "terraform_data" "retired_nodes" {
  triggers_replace = {
    nodes      = sort([for node in values(local.nodes) : node.name])
    cluster_id = rancher2_cluster_v2.this.id
  }

  depends_on = [hcloud_server.node]

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]
    environment = {
      CLUSTER_NAME      = var.config.cluster_name
      CLUSTER_ID        = rancher2_cluster_v2.this.id
      CLUSTER_V1_ID     = rancher2_cluster_v2.this.cluster_v1_id
      DESIRED_NODES     = jsonencode(sort([for node in values(local.nodes) : node.name]))
      MANAGEMENT_CONFIG = abspath("${path.module}/../../stacks/01-infra/kubeconfig.yaml")
      DOWNSTREAM_CONFIG = abspath("${path.root}/kubeconfig.yaml")
    }
    command = <<-SHELL
      set +x
      set -euo pipefail
      umask 077
      fail() { echo "ERROR: $*" >&2; exit 1; }
      NAME="$CLUSTER_NAME"
      for tool in kubectl jq; do command -v "$tool" >/dev/null || fail "$tool is required"; done
      [ -f "$MANAGEMENT_CONFIG" ] || fail 'Management kubeconfig is missing: stacks/01-infra/kubeconfig.yaml'
      [[ "$NAME" =~ ^[a-z0-9][-a-z0-9]*$ ]] || fail 'Invalid cluster name'
      [[ "$CLUSTER_ID" =~ ^[a-z0-9][-a-z0-9]*/[a-z0-9][-a-z0-9]*$ ]] || fail 'Invalid provisioning cluster_id'
      NAMESPACE="$(printf '%s' "$CLUSTER_ID" | cut -d/ -f1)"
      [ "$(printf '%s' "$CLUSTER_ID" | cut -d/ -f2)" = "$NAME" ] || fail 'Provisioning cluster_id differs from cluster name'
      WORK="$(mktemp -d)"
      trap 'rm -rf "$WORK"' EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      management() { kubectl --kubeconfig="$MANAGEMENT_CONFIG" --request-timeout=20s "$@"; }
      downstream() { kubectl --kubeconfig="$DOWNSTREAM_CONFIG" --request-timeout=20s "$@"; }

      printf '%s\n' "$DESIRED_NODES" >"$WORK/desired"
      jq -e --arg name "$NAME" 'type == "array" and length > 0 and
        all(.[]; type == "string" and test("^" + $name + "-(server|worker)-[0-9]+$"))' \
        "$WORK/desired" >/dev/null || fail 'Invalid desired node names'
      management get clusters.provisioning.cattle.io "$NAME" -n "$NAMESPACE" -o json >"$WORK/provisioning" 2>"$WORK/error" || fail 'Cannot read the Rancher provisioning cluster'
      jq -e --arg id "$CLUSTER_V1_ID" '.status.clusterName == $id and .metadata.deletionTimestamp == null' \
        "$WORK/provisioning" >/dev/null || fail 'Management kubeconfig points to a different or deleting cluster'
      management get clusters.cluster.x-k8s.io "$NAME" -n "$NAMESPACE" -o json >"$WORK/cluster" 2>"$WORK/error" || fail 'Cannot read the Cluster API cluster'
      CLUSTER_UID="$(jq -er '.metadata.uid | select(type == "string" and length > 0)' "$WORK/cluster")"
      jq -e '.metadata.deletionTimestamp == null' "$WORK/cluster" >/dev/null || fail 'Cluster is being deleted'
      management get machines.cluster.x-k8s.io -n "$NAMESPACE" -l "cluster.x-k8s.io/cluster-name=$NAME" -o json >"$WORK/machines" 2>"$WORK/error" || fail 'Cannot list Rancher Machines'

      # NodeRef and cluster ownership exclude unregistered and unrelated Machines.
      cat >"$WORK/candidates.jq" <<'JQ'
      def retired:
        . as $machine |
        .kind == "Machine" and
        (.apiVersion | test("^cluster\\.x-k8s\\.io/v[0-9]+(alpha[0-9]+|beta[0-9]+)?$")) and
        .metadata.namespace == $namespace and
        .metadata.labels["cluster.x-k8s.io/cluster-name"] == $name and
        any(.metadata.ownerReferences[]?; .kind == "Cluster" and .name == $name and .uid == $uid) and
        .spec.infrastructureRef.kind == "CustomMachine" and
        (.spec.infrastructureRef.apiGroup // (.spec.infrastructureRef.apiVersion // "" | split("/")[0])) == "rke.cattle.io" and
        .spec.infrastructureRef.name == .metadata.name and
        (.status.nodeRef.name // "" | test("^" + $name + "-(server|worker)-[0-9]+$")) and
        ($desired[0] | index($machine.status.nodeRef.name)) == null;
      def node_deleted:
        any(.status.conditions[]?; (.type == "NodeHealthy" or .type == "NodeReady") and
          .status == "False" and .reason == "NodeDeleted");
      JQ
      jq --arg name "$NAME" --arg namespace "$NAMESPACE" --arg uid "$CLUSTER_UID" \
        --slurpfile desired "$WORK/desired" "$(cat "$WORK/candidates.jq") [ .items[] | select(retired) ]" \
        "$WORK/machines" >"$WORK/candidates"
      if [ "$(jq length "$WORK/candidates")" -eq 0 ]; then
        echo "No orphaned Rancher Machines for $NAME."
        if [ ! -f "$DOWNSTREAM_CONFIG" ]; then
          echo 'No downstream kubeconfig yet; skipping Longhorn checks on first deployment.'
          exit 0
        fi
      fi
      [ -f "$DOWNSTREAM_CONFIG" ] || fail 'Downstream kubeconfig is missing; renew it and rerun apply'
      read_nodes() {
        downstream get nodes -o json >"$WORK/nodes" 2>"$WORK/error" || fail 'Cannot reach downstream nodes; rerun apply after restoring access'
      }
      read_nodes
      jq -r '.[] | [.metadata.name, .metadata.uid, .status.nodeRef.name] | @tsv' "$WORK/candidates" >"$WORK/list"
      while IFS=$'\t' read -r machine machine_uid node; do
        deadline=$((SECONDS + 600))
        while :; do
          management get machines.cluster.x-k8s.io "$machine" -n "$NAMESPACE" -o json >"$WORK/current" 2>"$WORK/error" || fail "Cannot recheck $machine; rerun apply"
          jq -e --arg name "$NAME" --arg namespace "$NAMESPACE" --arg uid "$CLUSTER_UID" \
            --arg machine_uid "$machine_uid" --arg node "$node" --slurpfile desired "$WORK/desired" \
            "$(cat "$WORK/candidates.jq") retired and .metadata.uid == \$machine_uid and .status.nodeRef.name == \$node" \
            "$WORK/current" >/dev/null || fail "$machine changed during cleanup; nothing further will be deleted"
          read_nodes
          if jq -e --arg node "$node" --slurpfile desired "$WORK/desired" '
            .items as $nodes | all($desired[0][]; . as $name |
              any($nodes[]; .metadata.name == $name and
                any(.status.conditions[]?; .type == "Ready" and .status == "True"))) and
            (any($nodes[]; .metadata.name == $node) | not)' "$WORK/nodes" >/dev/null &&
            jq -e "$(cat "$WORK/candidates.jq") node_deleted" "$WORK/current" >/dev/null; then
            break
          fi
          [ "$SECONDS" -lt "$deadline" ] || fail "Timed out waiting for $node retirement or desired nodes to become Ready; rerun apply"
          echo "Waiting for $node retirement and desired nodes to become Ready."
          sleep 5
        done
        echo "Removing retired Machine: $NAMESPACE/$machine ($node)."
        if jq -e '.metadata.deletionTimestamp == null' "$WORK/current" >/dev/null; then
          jq '{apiVersion:"v1",kind:"DeleteOptions",preconditions:{uid:.metadata.uid,resourceVersion:.metadata.resourceVersion}}' \
            "$WORK/current" >"$WORK/delete-options"
          API_VERSION="$(jq -r .apiVersion "$WORK/current")"
          management delete --raw "/apis/$API_VERSION/namespaces/$NAMESPACE/machines/$machine" \
            -f "$WORK/delete-options" >"$WORK/deleted" 2>"$WORK/error" || fail "Could not delete $machine; inspect Rancher and rerun apply"
        fi
        management wait --for=delete "machines.cluster.x-k8s.io/$machine" -n "$NAMESPACE" --timeout=300s \
          >"$WORK/wait" 2>"$WORK/error" || fail "$machine deletion is still pending; inspect Rancher and rerun apply without removing finalizers"
        echo "Removed retired Machine $machine."
      done <"$WORK/list"

      downstream get customresourcedefinitions nodes.longhorn.io --ignore-not-found -o name >"$WORK/longhorn-crd" 2>"$WORK/error" || fail 'Cannot discover Longhorn; rerun apply after restoring access'
      [ -s "$WORK/longhorn-crd" ] || exit 0
      downstream get nodes.longhorn.io -n longhorn-system -o json >"$WORK/longhorn-nodes" 2>"$WORK/error" || fail 'Cannot list Longhorn Nodes'
      jq -r --arg name "$NAME" --slurpfile desired "$WORK/desired" '
        .items[] | .metadata.name as $node |
        select(($node | test("^" + $name + "-(server|worker)-[0-9]+$")) and
          ($desired[0] | index($node)) == null) |
        [.metadata.name,.metadata.uid] | @tsv' "$WORK/longhorn-nodes" >"$WORK/longhorn-list"
      storage_unused() {
        jq -e 'all(.status.diskStatus[]?;
          (.scheduledReplica // {} | length) == 0 and
          (.scheduledBackingImage // {} | length) == 0)' "$WORK/longhorn-current" >/dev/null || fail "$node still has scheduled Longhorn data; evacuate it before retrying"
        for resource in replicas engines volumes backingimages; do
          downstream get "$resource.longhorn.io" -n longhorn-system -o json >"$WORK/$resource" 2>"$WORK/error" || fail "Cannot inspect Longhorn $resource; nothing further will be deleted"
        done
        jq -e --arg node "$node" --slurpfile engines "$WORK/engines" --slurpfile volumes "$WORK/volumes" '
          all(.items[]; .spec.nodeID != $node) and
          all($engines[0].items[]; .spec.nodeID != $node) and
          all($volumes[0].items[]; .spec.nodeID != $node and
            .status.currentNodeID != $node and .status.pendingNodeID != $node)' \
          "$WORK/replicas" >/dev/null || fail "$node is referenced by Longhorn storage; evacuate it before retrying"
        jq -e --slurpfile node "$WORK/longhorn-current" '
          [$node[0].status.diskStatus[]?.diskUUID | select(. != null)] as $disks |
          all(.items[]; ((.spec.diskFileSpecMap // {} | keys) + (.spec.disks // {} | keys)) as $refs |
            all($refs[]; . as $disk | ($disks | index($disk)) == null))' \
          "$WORK/backingimages" >/dev/null || fail "$node disks are referenced by Longhorn backing images; evacuate them before retrying"
      }
      while IFS=$'\t' read -r node node_uid; do
        deadline=$((SECONDS + 600))
        while :; do
          downstream get nodes.longhorn.io "$node" -n longhorn-system --ignore-not-found -o json >"$WORK/longhorn-current" 2>"$WORK/error" || fail "Cannot recheck Longhorn Node $node"
          [ -s "$WORK/longhorn-current" ] || break
          jq -e --arg uid "$node_uid" '.metadata.uid == $uid' "$WORK/longhorn-current" >/dev/null || fail "Longhorn Node $node was recreated; nothing further will be deleted"
          read_nodes
          if jq -e --arg node "$node" --slurpfile desired "$WORK/desired" '
            .items as $nodes | all($desired[0][]; . as $name |
              any($nodes[]; .metadata.name == $name and
                any(.status.conditions[]?; .type == "Ready" and .status == "True"))) and
            (any($nodes[]; .metadata.name == $node) | not)' "$WORK/nodes" >/dev/null &&
            jq -e 'any(.status.conditions[]?; .type == "Ready" and .status == "False")' "$WORK/longhorn-current" >/dev/null; then
            break
          fi
          [ "$SECONDS" -lt "$deadline" ] || fail "Timed out waiting for Longhorn Node $node to retire; rerun apply"
          echo "Waiting for Longhorn Node $node to retire."
          sleep 5
        done
        [ -s "$WORK/longhorn-current" ] || continue
        storage_unused
        jq '{metadata:{uid:.metadata.uid,resourceVersion:.metadata.resourceVersion},
          spec:{allowScheduling:false,disks:(.spec.disks | with_entries(.value.allowScheduling=false))}}' \
          "$WORK/longhorn-current" >"$WORK/longhorn-patch"
        downstream patch nodes.longhorn.io "$node" -n longhorn-system --type=merge --patch-file="$WORK/longhorn-patch" \
          >"$WORK/patched" 2>"$WORK/error" || fail "Could not disable scheduling on retired Longhorn Node $node"
        downstream get nodes.longhorn.io "$node" -n longhorn-system -o json >"$WORK/longhorn-current" 2>"$WORK/error" || fail "Cannot recheck Longhorn Node $node after disabling scheduling"
        jq -e --arg uid "$node_uid" '.metadata.uid == $uid and .spec.allowScheduling == false and
          all(.spec.disks[]?; .allowScheduling == false)' "$WORK/longhorn-current" >/dev/null || fail "Longhorn Node $node changed during cleanup"
        storage_unused
        read_nodes
        jq -e --arg node "$node" 'all(.items[]; .metadata.name != $node)' "$WORK/nodes" >/dev/null || fail "$node reappeared; its Longhorn record is preserved"
        jq '{apiVersion:"v1",kind:"DeleteOptions",preconditions:{uid:.metadata.uid,resourceVersion:.metadata.resourceVersion}}' \
          "$WORK/longhorn-current" >"$WORK/delete-options"
        API_VERSION="$(jq -er '.apiVersion | select(test("^longhorn\\.io/v[0-9]+(alpha[0-9]+|beta[0-9]+)?$"))' "$WORK/longhorn-current")"
        downstream delete --raw "/apis/$API_VERSION/namespaces/longhorn-system/nodes/$node" \
          -f "$WORK/delete-options" >"$WORK/deleted" 2>"$WORK/error" || fail "Could not delete Longhorn Node $node; inspect Longhorn and rerun apply"
        downstream wait --for=delete "nodes.longhorn.io/$node" -n longhorn-system --timeout=300s \
          >"$WORK/wait" 2>"$WORK/error" || fail "Longhorn Node $node deletion is still pending; rerun apply without removing finalizers"
        echo "Removed retired Longhorn Node $node."
      done <"$WORK/longhorn-list"
    SHELL
  }
}

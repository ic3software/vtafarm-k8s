# Replicated block storage for Vault's Raft and audit volumes. The RKE2 nodes
# are already prepared for it: cloud-init installs open-iscsi and nfs-common and
# enables iscsid, which is all Longhorn asks of the host.
resource "helm_release" "longhorn" {
  name             = "longhorn"
  repository       = "https://charts.longhorn.io"
  chart            = "longhorn"
  version          = var.config.longhorn_version
  namespace        = "longhorn-system"
  create_namespace = true

  set {
    name  = "persistence.defaultClass"
    value = tostring(var.config.longhorn_default_class)
  }

  set {
    name  = "persistence.defaultClassReplicaCount"
    value = tostring(var.config.longhorn_replica_count)
  }

  set {
    name  = "defaultSettings.defaultReplicaCount"
    value = tostring(var.config.longhorn_replica_count)
  }

  # Longhorn's own UI carries no authentication. Leave it unpublished and reach
  # it with a port-forward, the same way the Vault UI is handled.
  set {
    name  = "ingress.enabled"
    value = "false"
  }

  # The chart's pre-delete hook job aborts with BackoffLimitExceeded unless this
  # is true, which leaves `tofu destroy` unable to finish and the release stuck
  # in `uninstalling`. It is the guard against deleting Longhorn while it still
  # holds volumes - turning it on means a destroy takes the Vault Raft data with
  # it, without a second prompt.
  set {
    name  = "defaultSettings.deletingConfirmationFlag"
    value = "true"
  }

  wait    = true
  timeout = 900
}

# The RKE2 module installs hcloud-csi, which ships its own StorageClass. Two
# classes both claiming to be default is undefined behaviour in Kubernetes -
# the API server picks one and PVCs silently land on the wrong storage. Demote
# hcloud-volumes explicitly rather than depending on the chart's current default.
resource "kubernetes_annotations" "hcloud_volumes_not_default" {
  count = var.config.longhorn_default_class ? 1 : 0

  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  force       = true

  metadata {
    name = "hcloud-volumes"
  }

  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  depends_on = [helm_release.longhorn]
}

# Longhorn's own class deletes the volume with the PVC, which is right for a
# tenant's session and wrong for a database. reclaimPolicy is immutable, so this
# is a second class rather than a change to that one.
resource "kubernetes_storage_class_v1" "longhorn_retain" {
  metadata {
    name = "longhorn-retain"
  }

  storage_provisioner    = "driver.longhorn.io"
  reclaim_policy         = "Retain"
  allow_volume_expansion = true
  volume_binding_mode    = "Immediate"

  parameters = {
    numberOfReplicas    = tostring(var.config.longhorn_replica_count)
    staleReplicaTimeout = "30"
    fsType              = "ext4"
  }

  depends_on = [helm_release.longhorn]
}

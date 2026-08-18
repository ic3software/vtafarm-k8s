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

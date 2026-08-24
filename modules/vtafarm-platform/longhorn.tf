# Replicated block storage for Vault's Raft and audit volumes. The RKE2 nodes
# are already prepared for it: cloud-init installs open-iscsi and nfs-common and
# enables iscsid, which is all Longhorn asks of the host.
locals {
  longhorn_backup_credential_secret = "longhorn-backup-s3"
  longhorn_backup_recurring_job     = "longhorn-daily-backup"
  longhorn_backup_target = format(
    "s3://%s@%s/%s/",
    var.config.longhorn_backup_s3_bucket,
    var.config.longhorn_backup_s3_region,
    trim(var.config.longhorn_backup_s3_prefix, "/"),
  )
}

resource "helm_release" "longhorn" {
  name             = "longhorn"
  repository       = "https://charts.longhorn.io"
  chart            = "longhorn"
  version          = var.config.longhorn_version
  namespace        = "longhorn-system"
  create_namespace = true

  values = [yamlencode({
    # RecurringJob does not expose CronJob's timeZone field. RKE2 control-plane
    # nodes run UTC; pin Longhorn to the same zone so its schedule and logs agree.
    global = {
      timezone = "UTC"
    }
    defaultBackupStore = var.config.longhorn_backup_enabled ? {
      backupTarget                 = local.longhorn_backup_target
      backupTargetCredentialSecret = local.longhorn_backup_credential_secret
    } : {}
    defaultSettings = {
      allowRecurringJobWhileVolumeDetached = var.config.longhorn_backup_enabled
    }
    # The default group covers existing and future volumes without attempting
    # to mutate the parameters of an already-created StorageClass.
    extraObjects = var.config.longhorn_backup_enabled ? [{
      apiVersion = "longhorn.io/v1beta2"
      kind       = "RecurringJob"
      metadata = {
        name      = local.longhorn_backup_recurring_job
        namespace = "longhorn-system"
      }
      spec = {
        concurrency = 1
        cron        = var.config.longhorn_backup_schedule
        groups      = ["default"]
        retain      = var.config.longhorn_backup_retention
        task        = "backup"
      }
    }] : []
  })]

  set = [
    {
      name  = "persistence.defaultClass"
      value = tostring(var.config.longhorn_default_class)
    },
    {
      name  = "persistence.defaultClassReplicaCount"
      value = tostring(var.config.longhorn_replica_count)
    },
    {
      name  = "defaultSettings.defaultReplicaCount"
      value = tostring(var.config.longhorn_replica_count)
    },
    # Longhorn's own UI carries no authentication. Leave it unpublished and reach
    # it with a port-forward, the same way the Vault UI is handled.
    {
      name  = "ingress.enabled"
      value = "false"
    },
    # The chart's pre-delete hook job aborts with BackoffLimitExceeded unless this
    # is true, which leaves `tofu destroy` unable to finish and the release stuck
    # in `uninstalling`. It is the guard against deleting Longhorn while it still
    # holds volumes - turning it on means a destroy takes the Vault Raft data with
    # it, without a second prompt.
    {
      name  = "defaultSettings.deletingConfirmationFlag"
      value = "true"
    },
  ]

  wait    = true
  timeout = 900
}

# The chart creates the namespace, so the credential follows the release on a
# fresh install. Longhorn continuously reconciles the target and starts using
# the secret as soon as it appears.
resource "kubernetes_secret_v1" "longhorn_backup_s3" {
  count = var.config.longhorn_backup_enabled ? 1 : 0

  metadata {
    name      = local.longhorn_backup_credential_secret
    namespace = helm_release.longhorn.namespace
  }

  # These names are fixed by Longhorn's S3-compatible backupstore client.
  data = {
    AWS_ACCESS_KEY_ID     = var.config.longhorn_backup_s3_access_key
    AWS_SECRET_ACCESS_KEY = var.config.longhorn_backup_s3_secret_key
    AWS_ENDPOINTS         = var.config.longhorn_backup_s3_endpoint
  }

  type = "Opaque"
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

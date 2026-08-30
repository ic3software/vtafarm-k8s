variable "config" {
  description = "Non-secret configuration for the vtafarm platform layer on one downstream RKE2 cluster."
  type = object({
    cluster_name = string

    cert_manager_version = optional(string, "v1.21.1")

    longhorn_version = optional(string, "1.12.1")
    # Vault's Raft already replicates, and node NVMe is the whole budget.
    longhorn_replica_count = optional(number, 1)
    longhorn_node_drain_policy = optional(
      string,
      "block-for-eviction-if-contains-last-replica",
    )
    # Longhorn owns the default class, so Vault's PVCs land on it without every
    # chart naming it. hcloud-volumes stays available by name.
    longhorn_default_class = optional(bool, true)

    longhorn_backup_enabled       = optional(bool, false)
    longhorn_backup_s3_endpoint   = optional(string, "")
    longhorn_backup_s3_region     = optional(string, "")
    longhorn_backup_s3_bucket     = optional(string, "")
    longhorn_backup_s3_prefix     = optional(string, "longhorn")
    longhorn_backup_s3_access_key = optional(string, "")
    longhorn_backup_s3_secret_key = optional(string, "")
    longhorn_backup_schedule      = optional(string, "0 0 * * *")
    longhorn_backup_retention     = optional(number, 30)

    vault_chart_version = optional(string, "0.33.0")
    vault_namespace     = optional(string, "vault")
    vault_replicas      = optional(number, 3)
    vault_data_size     = optional(string, "10Gi")

    transit_namespace = optional(string, "vault-transit")
    transit_data_size = optional(string, "1Gi")

    # Empty means "whatever the cluster default is". Naming it explicitly is
    # better for a secrets store: the PVC then survives a change of default.
    storage_class = optional(string, "longhorn")
  })

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.config.cluster_name))
    error_message = "cluster_name must be a lowercase DNS-safe name."
  }

  # The vault chart's pod anti-affinity is HARD (one pod per node), so more
  # replicas than nodes leaves the extras Pending forever. Raft also wants an
  # odd count for quorum, exactly like the k3s etcd cluster in stack 01.
  validation {
    condition     = var.config.vault_replicas >= 1 && var.config.vault_replicas % 2 == 1 && var.config.vault_replicas <= 7
    error_message = "vault_replicas must be an odd number between 1 and 7 so Raft has quorum."
  }

  validation {
    condition     = var.config.longhorn_replica_count >= 1 && var.config.longhorn_replica_count <= 5
    error_message = "longhorn_replica_count must be between 1 and 5."
  }

  validation {
    condition = contains([
      "block-if-contains-last-replica",
      "allow-if-replica-is-stopped",
      "always-allow",
      "block-for-eviction",
      "block-for-eviction-if-contains-last-replica",
    ], var.config.longhorn_node_drain_policy)
    error_message = "longhorn_node_drain_policy must be a supported Longhorn node drain policy."
  }

  validation {
    condition = !var.config.longhorn_backup_enabled || alltrue([
      for value in [
        var.config.longhorn_backup_s3_endpoint,
        var.config.longhorn_backup_s3_region,
        var.config.longhorn_backup_s3_bucket,
        var.config.longhorn_backup_s3_access_key,
        var.config.longhorn_backup_s3_secret_key,
      ] : trimspace(value) != ""
    ])
    error_message = "Longhorn S3 endpoint, region, bucket, access key, and secret key are required when backups are enabled."
  }

  validation {
    condition     = !var.config.longhorn_backup_enabled || can(regex("^https?://", var.config.longhorn_backup_s3_endpoint))
    error_message = "longhorn_backup_s3_endpoint must be an http(s) URL."
  }

  validation {
    condition     = !var.config.longhorn_backup_enabled || var.config.longhorn_backup_retention >= 1
    error_message = "longhorn_backup_retention must be at least 1."
  }

  validation {
    condition     = var.config.vault_namespace != var.config.transit_namespace
    error_message = "The farm and transit Vaults must live in separate namespaces; the transit NetworkPolicy distinguishes them by namespace."
  }
}

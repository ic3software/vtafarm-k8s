variable "config" {
  description = "Non-secret configuration for the vtafarm platform layer on one downstream RKE2 cluster."
  type = object({
    cluster_name = string

    cert_manager_version = optional(string, "v1.21.1")

    longhorn_version       = optional(string, "1.12.1")
    longhorn_replica_count = optional(number, 3)
    # Longhorn owns the default class, so Vault's PVCs get replicated storage
    # without every chart naming it. hcloud-volumes stays available by name.
    longhorn_default_class = optional(bool, true)

    vault_chart_version = optional(string, "0.33.0")
    vault_namespace     = optional(string, "vault")
    vault_replicas      = optional(number, 3)
    vault_data_size     = optional(string, "10Gi")
    vault_audit_size    = optional(string, "10Gi")

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
    condition     = var.config.vault_namespace != var.config.transit_namespace
    error_message = "The farm and transit Vaults must live in separate namespaces; the transit NetworkPolicy distinguishes them by namespace."
  }
}

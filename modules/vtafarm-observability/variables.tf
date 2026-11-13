variable "config" {
  description = "Prometheus-based observability for one downstream RKE2 cluster."
  type = object({
    cluster_name = string

    enabled       = optional(bool, false)
    namespace     = optional(string, "monitoring")
    chart_version = optional(string, "93.2.2")

    storage_class_name        = optional(string, "hcloud-volumes-retain")
    prometheus_storage_size   = optional(string, "50Gi")
    prometheus_retention      = optional(string, "15d")
    prometheus_retention_size = optional(string, "40GB")
    scrape_interval           = optional(string, "30s")
    evaluation_interval       = optional(string, "30s")

    prometheus_cpu_request    = optional(string, "250m")
    prometheus_memory_request = optional(string, "1Gi")
    prometheus_memory_limit   = optional(string, "3Gi")

    grafana_enabled      = optional(bool, true)
    alertmanager_enabled = optional(bool, true)
  })

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.config.cluster_name))
    error_message = "cluster_name must be a lowercase DNS-safe name."
  }

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.config.namespace))
    error_message = "namespace must be a lowercase DNS-safe name."
  }

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$", var.config.storage_class_name))
    error_message = "storage_class_name must be a valid Kubernetes StorageClass name."
  }

  validation {
    condition = alltrue([
      can(regex("^[1-9][0-9]*(Ki|Mi|Gi|Ti)$", var.config.prometheus_storage_size)),
      can(regex("^[1-9][0-9]*(Ki|Mi|Gi|Ti)$", var.config.prometheus_memory_request)),
      can(regex("^[1-9][0-9]*(Ki|Mi|Gi|Ti)$", var.config.prometheus_memory_limit)),
    ])
    error_message = "Prometheus storage and memory values must be positive binary Kubernetes quantities such as 50Gi or 512Mi."
  }

  validation {
    condition     = can(regex("^[1-9][0-9]*m$", var.config.prometheus_cpu_request))
    error_message = "prometheus_cpu_request must use positive millicores such as 250m."
  }

  validation {
    condition     = can(regex("^[1-9][0-9]*(s|m|h|d|w|y)$", var.config.prometheus_retention))
    error_message = "prometheus_retention must be a positive Prometheus duration such as 15d."
  }

  validation {
    condition     = can(regex("^[1-9][0-9]*(KB|MB|GB|TB|PB|EB)$", var.config.prometheus_retention_size))
    error_message = "prometheus_retention_size must use Prometheus SI units such as 40GB."
  }

  validation {
    condition = alltrue([
      can(regex("^[1-9][0-9]*(ms|s|m|h)$", var.config.scrape_interval)),
      can(regex("^[1-9][0-9]*(ms|s|m|h)$", var.config.evaluation_interval)),
    ])
    error_message = "scrape_interval and evaluation_interval must be positive Prometheus durations such as 30s."
  }
}

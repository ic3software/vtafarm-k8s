variable "config" {
  description = "Prometheus-based observability for one downstream RKE2 cluster."
  type = object({
    cluster_name = string

    enabled       = optional(bool, false)
    namespace     = optional(string, "monitoring")
    chart_version = optional(string, "93.2.2")

    storage_class_name        = optional(string, "hcloud-volumes-retain")
    prometheus_storage_size   = optional(string, "50Gi")
    prometheus_retention      = optional(string, "30d")
    prometheus_retention_size = optional(string, "40GB")
    scrape_interval           = optional(string, "30s")
    evaluation_interval       = optional(string, "30s")

    prometheus_replicas       = optional(number, 1)
    prometheus_cpu_request    = optional(string, "250m")
    prometheus_cpu_limit      = optional(string)
    prometheus_memory_request = optional(string, "1Gi")
    prometheus_memory_limit   = optional(string, "3Gi")

    thanos_enabled                   = optional(bool, true)
    thanos_chart_version             = optional(string, "0.49.0")
    thanos_image_version             = optional(string, "v0.42.5")
    thanos_s3_bucket                 = optional(string, "")
    thanos_s3_prefix                 = optional(string, "")
    thanos_s3_endpoint               = optional(string, "")
    thanos_s3_region                 = optional(string, "")
    thanos_s3_access_key             = optional(string, "")
    thanos_s3_secret_key             = optional(string, "")
    thanos_retention                 = optional(string, "30d")
    thanos_query_replicas            = optional(number, 2)
    thanos_storegateway_replicas     = optional(number, 2)
    thanos_storegateway_storage_size = optional(string, "10Gi")
    thanos_compactor_storage_size    = optional(string, "50Gi")

    grafana_enabled      = optional(bool, true)
    alertmanager_enabled = optional(bool, false)
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
      can(regex("^[1-9][0-9]*(Ki|Mi|Gi|Ti)$", var.config.thanos_storegateway_storage_size)),
      can(regex("^[1-9][0-9]*(Ki|Mi|Gi|Ti)$", var.config.thanos_compactor_storage_size)),
    ])
    error_message = "Prometheus and Thanos storage and memory values must be positive binary Kubernetes quantities such as 50Gi or 512Mi."
  }

  validation {
    condition = (
      var.config.prometheus_replicas >= 1 &&
      var.config.prometheus_replicas <= 5 &&
      floor(var.config.prometheus_replicas) == var.config.prometheus_replicas
    )
    error_message = "prometheus_replicas must be a whole number from 1 to 5."
  }

  validation {
    condition = (
      can(regex("^([1-9][0-9]*m|[1-9][0-9]*)$", var.config.prometheus_cpu_request)) &&
      (var.config.prometheus_cpu_limit == null || can(regex("^([1-9][0-9]*m|[1-9][0-9]*)$", var.config.prometheus_cpu_limit)))
    )
    error_message = "Prometheus CPU request and optional limit must be positive Kubernetes quantities such as 250m or 1."
  }

  validation {
    condition     = can(regex("^[1-9][0-9]*(s|m|h|d|w|y)$", var.config.prometheus_retention))
    error_message = "prometheus_retention must be a positive Prometheus duration such as 30d."
  }

  validation {
    condition     = can(regex("^[1-9][0-9]*(s|m|h|d|w|y)$", var.config.thanos_retention))
    error_message = "thanos_retention must be a positive Prometheus duration such as 30d."
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

  validation {
    condition = alltrue([
      var.config.thanos_query_replicas >= 1,
      var.config.thanos_query_replicas <= 5,
      floor(var.config.thanos_query_replicas) == var.config.thanos_query_replicas,
      var.config.thanos_storegateway_replicas >= 1,
      var.config.thanos_storegateway_replicas <= 5,
      floor(var.config.thanos_storegateway_replicas) == var.config.thanos_storegateway_replicas,
    ])
    error_message = "Thanos Query and Store Gateway replicas must be whole numbers from 1 to 5."
  }

  validation {
    condition = (
      !var.config.enabled ||
      !var.config.thanos_enabled ||
      alltrue([
        trimspace(var.config.thanos_chart_version) != "",
        trimspace(var.config.thanos_image_version) != "",
        trimspace(var.config.thanos_s3_bucket) != "",
        trimspace(var.config.thanos_s3_endpoint) != "",
        trimspace(var.config.thanos_s3_region) != "",
        trimspace(var.config.thanos_s3_access_key) != "",
        trimspace(var.config.thanos_s3_secret_key) != "",
      ])
    )
    error_message = "Thanos chart, image, bucket, endpoint, region, access key, and secret key must be set when observability and Thanos are enabled."
  }

  validation {
    condition = (
      !var.config.enabled ||
      !var.config.thanos_enabled ||
      (
        can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.config.thanos_s3_bucket)) &&
        can(regex("^[A-Za-z0-9.-]+(?::[0-9]+)?$", var.config.thanos_s3_endpoint))
      )
    )
    error_message = "Thanos S3 bucket and endpoint must be DNS-safe; endpoint must not include a URL scheme or path."
  }

  validation {
    condition = (
      var.config.thanos_s3_prefix == "" ||
      (
        trimspace(var.config.thanos_s3_prefix) == var.config.thanos_s3_prefix &&
        can(regex("^[A-Za-z0-9._/-]+$", var.config.thanos_s3_prefix)) &&
        !startswith(var.config.thanos_s3_prefix, "/") &&
        !endswith(var.config.thanos_s3_prefix, "/") &&
        !strcontains(var.config.thanos_s3_prefix, "//")
      )
    )
    error_message = "thanos_s3_prefix must be empty or a slash-separated object prefix without spaces, leading/trailing slashes, or empty segments."
  }
}

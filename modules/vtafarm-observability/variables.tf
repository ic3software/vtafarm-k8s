variable "config" {
  description = "Metrics and logging observability for one downstream RKE2 cluster."
  type = object({
    cluster_name = string

    enabled              = optional(bool, false)
    monitoring_namespace = optional(string, "monitoring")
    logging_namespace    = optional(string, "logging")
    chart_version        = optional(string, "93.2.2")

    storage_class_name        = optional(string, "hcloud-volumes-retain")
    prometheus_storage_size   = optional(string, "20Gi")
    prometheus_retention      = optional(string, "30d")
    prometheus_retention_size = optional(string, "16GB")
    scrape_interval           = optional(string, "30s")
    evaluation_interval       = optional(string, "30s")

    prometheus_replicas       = optional(number, 1)
    prometheus_cpu_request    = optional(string, "250m")
    prometheus_cpu_limit      = optional(string)
    prometheus_memory_request = optional(string, "1Gi")
    prometheus_memory_limit   = optional(string, "3Gi")

    thanos_enabled                    = optional(bool, true)
    thanos_chart_version              = optional(string, "0.49.0")
    thanos_s3_bucket                  = optional(string, "")
    thanos_s3_prefix                  = optional(string, "")
    thanos_s3_endpoint                = optional(string, "")
    thanos_s3_region                  = optional(string, "")
    thanos_s3_access_key              = optional(string, "")
    thanos_s3_secret_key              = optional(string, "")
    thanos_retention                  = optional(string, "30d")
    thanos_query_replicas             = optional(number, 2)
    thanos_query_frontend_replicas    = optional(number, 2)
    thanos_storegateway_replicas      = optional(number, 2)
    thanos_storegateway_storage_class = optional(string, "longhorn")
    thanos_storegateway_storage_size  = optional(string, "3Gi")
    thanos_compactor_storage_class    = optional(string, "hcloud-volumes")
    thanos_compactor_storage_size     = optional(string, "50Gi")

    loki_enabled          = optional(bool, false)
    loki_chart_version    = optional(string, "21.4.0")
    alloy_chart_version   = optional(string, "1.16.0")
    loki_replicas         = optional(number, 1)
    loki_gateway_replicas = optional(number, 1)
    loki_storage_class    = optional(string, "hcloud-volumes-retain")
    loki_storage_size     = optional(string, "10Gi")
    loki_retention        = optional(string, "720h")
    loki_s3_chunks_bucket = optional(string, "")
    loki_s3_ruler_bucket  = optional(string, "")
    loki_s3_chunks_prefix = optional(string, "loki-chunks")
    loki_s3_ruler_prefix  = optional(string, "loki-ruler")
    loki_s3_endpoint      = optional(string, "")
    loki_s3_region        = optional(string, "")
    loki_s3_access_key    = optional(string, "")
    loki_s3_secret_key    = optional(string, "")

    grafana_enabled      = optional(bool, true)
    alertmanager_enabled = optional(bool, false)
  })

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.config.cluster_name))
    error_message = "cluster_name must be a lowercase DNS-safe name."
  }

  validation {
    condition = (
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.config.monitoring_namespace)) &&
      can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.config.logging_namespace)) &&
      var.config.monitoring_namespace != var.config.logging_namespace
    )
    error_message = "Metrics and logging namespaces must be distinct lowercase DNS-safe names."
  }

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$", var.config.storage_class_name))
    error_message = "storage_class_name must be a valid Kubernetes StorageClass name."
  }

  validation {
    condition = alltrue([
      can(regex("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$", var.config.thanos_storegateway_storage_class)),
      can(regex("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$", var.config.thanos_compactor_storage_class)),
      can(regex("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$", var.config.loki_storage_class)),
    ])
    error_message = "Thanos and Loki StorageClass names must be valid Kubernetes StorageClass names."
  }

  validation {
    condition = alltrue([
      can(regex("^[1-9][0-9]*(Ki|Mi|Gi|Ti)$", var.config.prometheus_storage_size)),
      can(regex("^[1-9][0-9]*(Ki|Mi|Gi|Ti)$", var.config.prometheus_memory_request)),
      can(regex("^[1-9][0-9]*(Ki|Mi|Gi|Ti)$", var.config.prometheus_memory_limit)),
      can(regex("^[1-9][0-9]*(Ki|Mi|Gi|Ti)$", var.config.thanos_storegateway_storage_size)),
      can(regex("^[1-9][0-9]*(Ki|Mi|Gi|Ti)$", var.config.thanos_compactor_storage_size)),
      can(regex("^[1-9][0-9]*(Ki|Mi|Gi|Ti)$", var.config.loki_storage_size)),
    ])
    error_message = "Prometheus, Thanos, and Loki storage and memory values must be positive binary Kubernetes quantities such as 50Gi or 512Mi."
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
    condition     = can(regex("^[1-9][0-9]*(s|m|h)$", var.config.loki_retention))
    error_message = "loki_retention must be a positive Loki duration such as 720h."
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
      var.config.thanos_query_frontend_replicas >= 1,
      var.config.thanos_query_frontend_replicas <= 5,
      floor(var.config.thanos_query_frontend_replicas) == var.config.thanos_query_frontend_replicas,
      var.config.thanos_storegateway_replicas >= 1,
      var.config.thanos_storegateway_replicas <= 5,
      floor(var.config.thanos_storegateway_replicas) == var.config.thanos_storegateway_replicas,
    ])
    error_message = "Thanos Query, Query Frontend, and Store Gateway replicas must be whole numbers from 1 to 5."
  }

  validation {
    condition = (
      contains([1, 3], var.config.loki_replicas) &&
      var.config.loki_gateway_replicas >= 1 &&
      var.config.loki_gateway_replicas <= 5 &&
      floor(var.config.loki_gateway_replicas) == var.config.loki_gateway_replicas
    )
    error_message = "loki_replicas must be 1 or 3, and loki_gateway_replicas must be a whole number from 1 to 5."
  }

  validation {
    condition = (
      !var.config.enabled ||
      !var.config.thanos_enabled ||
      alltrue([
        trimspace(var.config.thanos_chart_version) != "",
        trimspace(var.config.thanos_s3_bucket) != "",
        trimspace(var.config.thanos_s3_endpoint) != "",
        trimspace(var.config.thanos_s3_region) != "",
        trimspace(var.config.thanos_s3_access_key) != "",
        trimspace(var.config.thanos_s3_secret_key) != "",
      ])
    )
    error_message = "Thanos chart, bucket, endpoint, region, access key, and secret key must be set when observability and Thanos are enabled."
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
      !var.config.enabled ||
      !var.config.loki_enabled ||
      alltrue([
        trimspace(var.config.loki_chart_version) != "",
        trimspace(var.config.alloy_chart_version) != "",
        trimspace(var.config.loki_s3_chunks_bucket) != "",
        trimspace(var.config.loki_s3_ruler_bucket) != "",
        trimspace(var.config.loki_s3_endpoint) != "",
        trimspace(var.config.loki_s3_region) != "",
        trimspace(var.config.loki_s3_access_key) != "",
        trimspace(var.config.loki_s3_secret_key) != "",
      ])
    )
    error_message = "Loki and Alloy chart versions plus both buckets, endpoint, region, access key, and secret key must be set when observability logging is enabled."
  }

  validation {
    condition = (
      !var.config.enabled ||
      !var.config.loki_enabled ||
      (
        can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.config.loki_s3_chunks_bucket)) &&
        can(regex("^[a-z0-9][a-z0-9.-]*[a-z0-9]$", var.config.loki_s3_ruler_bucket)) &&
        can(regex("^[A-Za-z0-9.-]+(?::[0-9]+)?$", var.config.loki_s3_endpoint))
      )
    )
    error_message = "Loki chunks and ruler buckets must be DNS-safe names; the S3 endpoint must not include a URL scheme or path."
  }

  validation {
    condition = alltrue([
      can(regex("^[A-Za-z0-9-]+$", var.config.loki_s3_chunks_prefix)),
      can(regex("^[A-Za-z0-9-]+$", var.config.loki_s3_ruler_prefix)),
      var.config.loki_s3_chunks_prefix != var.config.loki_s3_ruler_prefix,
    ])
    error_message = "Loki chunks and ruler prefixes must be distinct and contain only letters, numbers, and hyphens."
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

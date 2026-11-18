variable "kubeconfig_path" {
  description = <<-EOT
    Kubeconfig for the downstream RKE2 cluster this stack installs into.

    Leave empty to use the file stack 03 writes for the cluster of the same
    name: ../../../03-rke2-clusters/clusters/<dir>/kubeconfig.yaml.
  EOT
  type        = string
  default     = ""
}

variable "observability_enabled" {
  description = "Install Prometheus, node-exporter, kube-state-metrics, and the selected operator interfaces."
  type        = bool
  default     = false
}

variable "observability_namespace" {
  description = "Namespace for the observability stack."
  type        = string
  default     = "monitoring"
}

variable "kube_prometheus_stack_version" {
  description = "Pinned prometheus-community/kube-prometheus-stack chart version."
  type        = string
  default     = "93.2.2"
}

variable "prometheus_storage_class" {
  description = "Retained Hetzner CSI StorageClass created for the Prometheus PVC."
  type        = string
  default     = "hcloud-volumes-retain"
}

variable "prometheus_storage_size" {
  description = "Hetzner Cloud Volume capacity requested by Prometheus."
  type        = string
  default     = "50Gi"
}

variable "prometheus_retention" {
  description = "Maximum time Prometheus keeps samples."
  type        = string
  default     = "30d"
}

variable "prometheus_retention_size" {
  description = "Maximum Prometheus TSDB size; keep it below the PVC size for WAL and compaction headroom."
  type        = string
  default     = "40GB"
}

variable "prometheus_scrape_interval" {
  description = "Interval between Prometheus target scrapes."
  type        = string
  default     = "30s"
}

variable "prometheus_evaluation_interval" {
  description = "Interval between recording and alert rule evaluations."
  type        = string
  default     = "30s"
}

variable "prometheus_cpu_request" {
  description = "CPU reserved for each Prometheus replica."
  type        = string
  default     = "250m"
}

variable "prometheus_cpu_limit" {
  description = "Optional CPU limit for each Prometheus replica. Null avoids query and compaction throttling."
  type        = string
  default     = null
  nullable    = true
}

variable "prometheus_replicas" {
  description = "Prometheus replicas. Each replica gets its own retained Hetzner Volume."
  type        = number
  default     = 1

  validation {
    condition     = var.prometheus_replicas >= 1 && var.prometheus_replicas <= 5 && floor(var.prometheus_replicas) == var.prometheus_replicas
    error_message = "prometheus_replicas must be a whole number from 1 to 5."
  }
}

variable "prometheus_memory_request" {
  description = "Memory reserved for each Prometheus replica."
  type        = string
  default     = "1Gi"
}

variable "prometheus_memory_limit" {
  description = "Hard memory limit for each Prometheus replica. Raise it if cardinality grows before the process is OOM-killed."
  type        = string
  default     = "3Gi"
}

variable "thanos_enabled" {
  description = "Upload Prometheus blocks to S3-compatible object storage and query them through Thanos."
  type        = bool
  default     = true
}

variable "thanos_chart_version" {
  description = "Pinned thanos-community/thanos chart version."
  type        = string
  default     = "0.49.0"
}

variable "thanos_s3_bucket" {
  description = "Private S3-compatible bucket containing the configured Thanos object prefix."
  type        = string
  default     = ""
}

variable "thanos_s3_prefix" {
  description = "Object prefix inside the shared bucket. Empty uses thanos/<cluster-name>."
  type        = string
  default     = ""
}

variable "thanos_s3_endpoint" {
  description = "S3-compatible endpoint without an URL scheme or path, for example nbg1.your-objectstorage.com."
  type        = string
  default     = ""
}

variable "thanos_s3_region" {
  description = "S3-compatible bucket region, for example nbg1."
  type        = string
  default     = ""
}

variable "thanos_s3_access_key" {
  description = "S3-compatible access key for the dedicated Thanos bucket."
  type        = string
  default     = ""
  sensitive   = true
}

variable "thanos_s3_secret_key" {
  description = "S3-compatible secret key for the dedicated Thanos bucket."
  type        = string
  default     = ""
  sensitive   = true
}

variable "thanos_retention" {
  description = "Maximum age of raw and downsampled metric blocks in object storage."
  type        = string
  default     = "30d"
}

variable "thanos_query_replicas" {
  description = "Thanos Query replicas."
  type        = number
  default     = 2

  validation {
    condition     = var.thanos_query_replicas >= 1 && var.thanos_query_replicas <= 5 && floor(var.thanos_query_replicas) == var.thanos_query_replicas
    error_message = "thanos_query_replicas must be a whole number from 1 to 5."
  }
}

variable "thanos_storegateway_replicas" {
  description = "Thanos Store Gateway replicas."
  type        = number
  default     = 2

  validation {
    condition     = var.thanos_storegateway_replicas >= 1 && var.thanos_storegateway_replicas <= 5 && floor(var.thanos_storegateway_replicas) == var.thanos_storegateway_replicas
    error_message = "thanos_storegateway_replicas must be a whole number from 1 to 5."
  }
}

variable "thanos_storegateway_storage_size" {
  description = "Longhorn capacity for each Store Gateway index cache."
  type        = string
  default     = "3Gi"
}

variable "thanos_storegateway_storage_class" {
  description = "StorageClass for each Store Gateway index cache."
  type        = string
  default     = "longhorn"
}

variable "thanos_compactor_storage_class" {
  description = "StorageClass for the Compactor workspace."
  type        = string
  default     = "hcloud-volumes"
}

variable "thanos_compactor_storage_size" {
  description = "Hetzner Cloud Volume capacity for the Compactor workspace."
  type        = string
  default     = "50Gi"
}

variable "loki_enabled" {
  description = "Install monolithic Loki plus an Alloy log collector on every node."
  type        = bool
  default     = true
}

variable "loki_chart_version" {
  description = "Pinned grafana-community/loki chart version."
  type        = string
  default     = "21.4.0"
}

variable "alloy_chart_version" {
  description = "Pinned grafana/alloy chart version."
  type        = string
  default     = "1.16.0"
}

variable "loki_replicas" {
  description = "Monolithic Loki replicas. Use 1 for dev and 3 for staging/production."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 3], var.loki_replicas)
    error_message = "loki_replicas must be 1 or 3."
  }
}

variable "loki_gateway_replicas" {
  description = "Loki gateway replicas. Use 1 for dev and 2 for staging/production."
  type        = number
  default     = 1

  validation {
    condition     = var.loki_gateway_replicas >= 1 && var.loki_gateway_replicas <= 5 && floor(var.loki_gateway_replicas) == var.loki_gateway_replicas
    error_message = "loki_gateway_replicas must be a whole number from 1 to 5."
  }
}

variable "loki_storage_class" {
  description = "Retained Hetzner CSI StorageClass used for each Loki WAL and working-state PVC."
  type        = string
  default     = "hcloud-volumes-retain"
}

variable "loki_storage_size" {
  description = "Capacity of each Loki working PVC. Use 10Gi for dev and 20Gi for staging/production."
  type        = string
  default     = "10Gi"
}

variable "loki_retention" {
  description = "Maximum age of logs in Loki object storage."
  type        = string
  default     = "720h"
}

variable "loki_s3_chunks_bucket" {
  description = "Private bucket for Loki chunks and TSDB indexes. Empty uses the shared loki bucket."
  type        = string
  default     = ""
}

variable "loki_s3_ruler_bucket" {
  description = "Private bucket for Loki ruler data. Empty uses the shared loki bucket."
  type        = string
  default     = ""
}

variable "loki_s3_endpoint" {
  description = "S3-compatible endpoint without a scheme. Empty reuses the Thanos endpoint."
  type        = string
  default     = ""
}

variable "loki_s3_region" {
  description = "S3-compatible bucket region. Empty reuses the Thanos region."
  type        = string
  default     = ""
}

variable "loki_s3_access_key" {
  description = "S3 access key for the Loki buckets. Empty reuses the Thanos access key."
  type        = string
  default     = ""
  sensitive   = true
}

variable "loki_s3_secret_key" {
  description = "S3 secret key for the Loki buckets. Empty reuses the Thanos secret key."
  type        = string
  default     = ""
  sensitive   = true
}

variable "grafana_enabled" {
  description = "Install private Grafana dashboards. No Ingress is created."
  type        = bool
  default     = true
}

variable "alertmanager_enabled" {
  description = "Install Alertmanager for the bundled Kubernetes alerts. Notification receivers are configured separately."
  type        = bool
  default     = false
}

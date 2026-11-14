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

variable "thanos_image_version" {
  description = "Pinned official Thanos image tag used by the sidecar and standalone components."
  type        = string
  default     = "v0.42.5"
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
  description = "Retained Hetzner Volume capacity for each Store Gateway index cache."
  type        = string
  default     = "10Gi"
}

variable "thanos_compactor_storage_size" {
  description = "Retained Hetzner Volume capacity for the Compactor workspace."
  type        = string
  default     = "50Gi"
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

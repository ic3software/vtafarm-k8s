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
  default     = "15d"
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
  description = "CPU reserved for Prometheus; no CPU limit is imposed."
  type        = string
  default     = "250m"
}

variable "prometheus_memory_request" {
  description = "Memory reserved for Prometheus."
  type        = string
  default     = "1Gi"
}

variable "prometheus_memory_limit" {
  description = "Hard Prometheus memory limit. Raise it if cardinality grows before the process is OOM-killed."
  type        = string
  default     = "3Gi"
}

variable "grafana_enabled" {
  description = "Install private Grafana dashboards. No Ingress is created."
  type        = bool
  default     = true
}

variable "alertmanager_enabled" {
  description = "Install Alertmanager for the bundled Kubernetes alerts. Notification receivers are configured separately."
  type        = bool
  default     = true
}

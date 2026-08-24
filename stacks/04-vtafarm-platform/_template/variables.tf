variable "kubeconfig_path" {
  description = <<-EOT
    Kubeconfig for the downstream RKE2 cluster this stack installs into.

    Leave empty to use the file stack 03 writes for the cluster of the same
    name: ../../../03-rke2-clusters/clusters/<dir>/kubeconfig.yaml, produced by
    make kubeconfig-rke2 CLUSTER=<dir>.
  EOT
  type        = string
  default     = ""
}

variable "cert_manager_version" {
  description = "cert-manager chart version. Keep it equal to stack 02 unless there is a reason to diverge."
  type        = string
  default     = "v1.21.1"
}

variable "longhorn_version" {
  description = "Longhorn chart version."
  type        = string
  default     = "1.12.1"
}

variable "longhorn_replica_count" {
  description = "Copies Longhorn keeps of every volume. Each one costs another volume-size of node disk and another schedulable node."
  type        = number
  default     = 1
}

variable "longhorn_default_class" {
  description = <<-EOT
    Make longhorn the cluster's default StorageClass and demote hcloud-volumes.

    Two default classes is undefined behaviour, so this flips both sides at
    once. Set false to leave Hetzner block storage as the default; Vault then
    still uses whatever storage_class names.
  EOT
  type        = bool
  default     = true
}

variable "longhorn_backup_enabled" {
  description = "Back up Longhorn volumes automatically to the configured S3-compatible bucket."
  type        = bool
  default     = true
}

variable "longhorn_backup_s3_endpoint" {
  description = "S3-compatible endpoint URL for Longhorn backups."
  type        = string
  default     = "https://nbg1.your-objectstorage.com"
}

variable "longhorn_backup_s3_region" {
  description = "S3 region used in the Longhorn backup target URL."
  type        = string
  default     = "nbg1"
}

variable "longhorn_backup_s3_bucket" {
  description = "Private S3 bucket that receives Longhorn volume backups."
  type        = string
}

variable "longhorn_backup_s3_prefix" {
  description = "Prefix inside the bucket. Empty defaults to longhorn/<cluster name>."
  type        = string
  default     = ""
}

variable "longhorn_backup_s3_access_key" {
  description = "S3 access key used by Longhorn."
  type        = string
  sensitive   = true
}

variable "longhorn_backup_s3_secret_key" {
  description = "S3 secret key used by Longhorn."
  type        = string
  sensitive   = true
}

variable "longhorn_backup_schedule" {
  description = "Cron schedule for Longhorn volume backups. Longhorn is pinned to UTC."
  type        = string
  default     = "0 0 * * *"
}

variable "longhorn_backup_retention" {
  description = "Number of successful backups to retain per Longhorn volume."
  type        = number
  default     = 30
}

variable "vault_chart_version" {
  description = "hashicorp/vault chart version. Bump deliberately; read the upstream changelog first."
  type        = string
  default     = "0.33.0"
}

variable "vault_namespace" {
  description = "Namespace for the farm Vault."
  type        = string
  default     = "vault"
}

variable "vault_replicas" {
  description = <<-EOT
    Raft peers in the farm Vault. Must be odd for quorum.

    The chart's pod anti-affinity is hard - one Vault pod per node - so this
    cannot exceed the cluster's schedulable node count without leaving pods
    Pending. Three matches the default RKE2 topology in stack 03.
  EOT
  type        = number
  default     = 3
}

variable "vault_data_size" {
  description = "PersistentVolume size for each farm Vault peer's Raft data."
  type        = string
  default     = "10Gi"
}

variable "vault_audit_size" {
  description = "PersistentVolume size for each farm Vault peer's audit log."
  type        = string
  default     = "10Gi"
}

variable "transit_namespace" {
  description = "Namespace for the standalone transit Vault providing auto-unseal."
  type        = string
  default     = "vault-transit"
}

variable "transit_data_size" {
  description = "PersistentVolume size for the transit Vault. It holds one key."
  type        = string
  default     = "1Gi"
}

variable "storage_class" {
  description = "StorageClass for every Vault volume. Empty means the cluster default."
  type        = string
  default     = "longhorn"
}

variable "kubeconfig_path" {
  description = "Kubeconfig produced by stack 01."
  type        = string
  default     = "../../kubeconfig"
}

# ---------------------------------------------------------------------------
# Rancher
# ---------------------------------------------------------------------------

variable "rancher_hostname" {
  description = <<-EOT
    Public DNS name for Rancher, e.g. rancher.example.com.
    An A record for it must already point at the load balancer, otherwise the
    Let's Encrypt HTTP-01 challenge cannot succeed.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$", var.rancher_hostname))
    error_message = "rancher_hostname must be a lowercase DNS name, not an IP."
  }
}

variable "letsencrypt_email" {
  description = "Contact address for Let's Encrypt expiry notices."
  type        = string
}

variable "letsencrypt_environment" {
  description = <<-EOT
    "production" or "staging". Let's Encrypt rate-limits production to 5 failed
    orders per hostname per hour, so use "staging" while you are still testing
    DNS - staging certificates are untrusted but unlimited.
  EOT
  type        = string
  default     = "production"

  validation {
    condition     = contains(["production", "staging"], var.letsencrypt_environment)
    error_message = "letsencrypt_environment must be production or staging."
  }
}

variable "rancher_bootstrap_password" {
  description = "First-login password for the Rancher admin user. Leave empty to generate one."
  type        = string
  default     = ""
  sensitive   = true
}

variable "rancher_replicas" {
  description = "Rancher pod replicas. Keep at 3 for HA; must be <= number of nodes."
  type        = number
  default     = 3
}

variable "rancher_chart_version" {
  description = <<-EOT
    Rancher chart version. The chart declares a kubeVersion range that helm
    enforces, so this and k3s_version in stack 01 must agree or the install
    fails outright:

      2.14.x  ->  kubeVersion < 1.36.0-0   (published in rancher-stable)
      2.15.x  ->  kubeVersion < 1.37.0-0   (published in rancher-latest)

    Moving to 2.15 also means bumping rancher_backup_chart_version, which is
    gated on the Rancher minor.
  EOT
  type        = string
  default     = "2.14.3"
}

variable "rancher_chart_repo" {
  description = <<-EOT
    Which Rancher channel to install from:
      https://releases.rancher.com/server-charts/stable  - Rancher's production recommendation
      https://releases.rancher.com/server-charts/latest  - newest release, less soak time
  EOT
  type        = string
  default     = "https://releases.rancher.com/server-charts/stable"
}

variable "cert_manager_version" {
  description = "cert-manager chart version."
  type        = string
  default     = "v1.21.1"
}

variable "ingress_class" {
  description = "Ingress class Rancher should use. k3s ships Traefik."
  type        = string
  default     = "traefik"
}

# ---------------------------------------------------------------------------
# Rancher Backup operator
#
# Backs up Rancher's own CRDs, users and cluster registrations - complementary
# to, not a replacement for, the etcd snapshots taken in stack 01.
# ---------------------------------------------------------------------------

variable "rancher_backup_chart_version" {
  description = <<-EOT
    Version of the rancher-backup / rancher-backup-crd charts. It is pinned to
    a Rancher minor by catalog.cattle.io/rancher-version, so it moves with
    rancher_chart_version:

      109.0.7+up10.0.8  ->  Rancher >= 2.14.0 < 2.15.0, Kubernetes >= 1.33 < 1.36
      110.0.0+up11.0.0  ->  Rancher >= 2.15.0 < 2.16.0, Kubernetes >= 1.33 < 1.36

    Inspect the whole matrix with:
      curl -s https://charts.rancher.io/index.yaml | yq '.entries.rancher-backup[].annotations'
  EOT
  type        = string
  default     = "109.0.7+up10.0.8"
}

variable "rancher_backup_schedule" {
  description = "Cron schedule for the Rancher backup."
  type        = string
  default     = "0 3 * * *"
}

variable "rancher_backup_retention" {
  description = "How many Rancher backups to keep."
  type        = number
  default     = 30
}

variable "backup_s3_endpoint" {
  description = "Hetzner Object Storage endpoint for Rancher backups."
  type        = string
  default     = "nbg1.your-objectstorage.com"
}

variable "backup_s3_region" {
  description = "Hetzner Object Storage location, e.g. nbg1."
  type        = string
  default     = "nbg1"
}

variable "backup_s3_bucket" {
  description = "Private Hetzner Object Storage bucket that stores Rancher backups."
  type        = string
}

variable "backup_s3_folder" {
  description = "Prefix inside the bucket for Rancher backups."
  type        = string
  default     = "rancher-backup"
}

variable "backup_s3_access_key" {
  description = "S3 access key."
  type        = string
  sensitive   = true
}

variable "backup_s3_secret_key" {
  description = "S3 secret key."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Automated k3s upgrades (rancher/system-upgrade-controller)
# ---------------------------------------------------------------------------

variable "system_upgrade_controller_version" {
  description = "Release tag of rancher/system-upgrade-controller."
  type        = string
  default     = "v0.20.1"
}

variable "k3s_target_version" {
  description = <<-EOT
    The k3s version the upgrade Plan should converge on. Set it to the version
    the cluster already runs; bumping it here (and re-applying) is what triggers
    a rolling, one-node-at-a-time upgrade.

    Must stay within rancher_chart_version's kubeVersion range - 2.14.x caps at
    v1.35, so do not raise this to v1.36 without moving Rancher to 2.15 first.
  EOT
  type        = string
  default     = "v1.35.7+k3s1"
}

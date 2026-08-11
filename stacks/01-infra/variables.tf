# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

variable "hcloud_token" {
  description = "Hetzner Cloud API token (Project -> Security -> API tokens, Read & Write)."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Cluster shape
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name prefix for every resource. Must be DNS-safe."
  type        = string
  default     = "k3s-ha"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric with dashes."
  }
}

variable "location" {
  description = <<-EOT
    Hetzner location. The private network's zone is derived from it, so this is
    the only knob - there is no second setting that has to agree with it.

      nbg1  Nuremberg, DE    eu-central
      fsn1  Falkenstein, DE  eu-central
      hel1  Helsinki, FI     eu-central
      ash   Ashburn, VA      us-east
      hil   Hillsboro, OR    us-west
      sin   Singapore        ap-southeast

    Machine types and prices differ per location; check the Console before
    moving. Changing this on a live cluster replaces every server - a server
    cannot migrate between locations.
  EOT
  type        = string
  default     = "nbg1"

  validation {
    condition     = contains(["fsn1", "nbg1", "hel1", "ash", "hil", "sin"], var.location)
    error_message = "Unknown location. If Hetzner has added one, extend this list and the network_zones map in locals.tf."
  }
}

variable "server_count" {
  description = <<-EOT
    Number of k3s server nodes. Every node is a control-plane + etcd member and
    also runs workloads.

    MUST be an odd number >= 3 so etcd can keep quorum ((n/2)+1). Three tolerates
    one failure; five tolerates two.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.server_count >= 3 && var.server_count % 2 == 1
    error_message = "server_count must be an odd number >= 3 (etcd quorum requirement)."
  }
}

variable "server_type" {
  description = <<-EOT
    Hetzner server type. Current shared-vCPU line:
      cx23  2 vCPU /  4 GB /  40 GB   <- default
      cx33  4 vCPU /  8 GB /  80 GB
      cx43  8 vCPU / 16 GB / 160 GB
      cx53 16 vCPU / 32 GB / 320 GB

    Stay on x86 (cx/cpx/ccx). The ARM64 line (cax) is cheaper, but Rancher
    documents ARM64 as experimental and not recommended for production.

    On cx23 the 4 GB budget is tight: k3s with etcd takes roughly 1 GB, a
    Rancher replica another 1-1.5 GB, and the bundled add-ons about 0.5 GB.
    It fits, with little headroom. If Rancher pods start getting OOMKilled -
    most likely during a Rancher upgrade, when replicas briefly double - move
    to cx33. See docs/troubleshooting.md.
  EOT
  type        = string
  default     = "cx23"
}

variable "os_image" {
  description = "Base image for all nodes."
  type        = string
  default     = "ubuntu-24.04"
}

# ---------------------------------------------------------------------------
# Networking
#
# Nodes are IPv4 only. Everything cluster-internal (etcd, the API, flannel,
# the kubelet) binds to the private network, and the public interface exposes
# nothing but SSH.
# ---------------------------------------------------------------------------

variable "network_cidr" {
  description = "CIDR of the private Hetzner network."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR of the node subnet inside network_cidr."
  type        = string
  default     = "10.0.1.0/24"
}

variable "cluster_cidr" {
  description = "Pod CIDR handed to k3s/flannel."
  type        = string
  default     = "10.42.0.0/16"
}

variable "service_cidr" {
  description = "Service CIDR handed to k3s."
  type        = string
  default     = "10.43.0.0/16"
}

variable "ssh_allowed_cidrs" {
  description = <<-EOT
    Source CIDRs allowed to reach port 22 on the nodes.
    Set this to your own IP - "0.0.0.0/0" leaves SSH open to the internet.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "load_balancer_type" {
  description = "Hetzner load balancer size. lb11 handles 5 services / 10k connections."
  type        = string
  default     = "lb11"
}

variable "enable_proxy_protocol" {
  description = <<-EOT
    Send PROXY protocol from the load balancer to Traefik on :80/:443 so that
    real client IPs survive. Traefik is configured to trust the private network.
    Not used on :6443 - the k3s API server does not speak it.
  EOT
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------

variable "ssh_public_key_path" {
  description = <<-EOT
    Path to an existing SSH public key. It is uploaded to Hetzner and installed
    in root's authorized_keys on every node. Point this at whatever key you
    already use; there is no need to generate a new one.

    Ignored when existing_ssh_key_name is set.
  EOT
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = <<-EOT
    The matching private key. Never leaves your machine - it is only used by
    scripts/fetch-kubeconfig.sh and scripts/etcd-snapshot.sh to reach the nodes.
    If it has a passphrase, load it first with `ssh-add` so those scripts do not
    stall on a prompt.
  EOT
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "existing_ssh_key_name" {
  description = <<-EOT
    Name of an SSH key ALREADY uploaded to this Hetzner project, as shown under
    Security -> SSH keys. Set this when the key is already there: Hetzner
    rejects a second upload of the same fingerprint, so letting Terraform create
    it would fail the apply.

    Leave empty to have Terraform upload ssh_public_key_path itself.
  EOT
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# k3s
# ---------------------------------------------------------------------------

variable "k3s_version" {
  description = <<-EOT
    Exact k3s version to install, e.g. "v1.35.7+k3s1".

    This MUST stay inside the range your Rancher version accepts. The Rancher
    chart declares a kubeVersion constraint that helm enforces, so a mismatch
    fails the install outright rather than degrading gracefully:

      Rancher 2.14.x  ->  kubeVersion < 1.36.0-0   (v1.33 / v1.34 / v1.35)
      Rancher 2.15.x  ->  kubeVersion < 1.37.0-0   (v1.34 / v1.35 / v1.36)

    The default pairs with Rancher 2.14.3 (stack 02) and is the newest k3s that
    release accepts. Do NOT follow the k3s "stable" channel blindly - it is on
    v1.36, which Rancher 2.14.x refuses.

    Check the current channel heads with:
      curl -s https://update.k3s.io/v1-release/channels | jq -r '.data[] | "\(.id)\t\(.latest)"'
  EOT
  type        = string
  default     = "v1.35.7+k3s1"
}

variable "additional_tls_sans" {
  description = "Extra hostnames/IPs added to the Kubernetes API server certificate."
  type        = list(string)
  default     = []
}

variable "hcloud_ccm_version" {
  description = "Chart version of hcloud-cloud-controller-manager (charts.hetzner.cloud)."
  type        = string
  default     = "1.34.0"
}

variable "hcloud_csi_version" {
  description = "Chart version of hcloud-csi (charts.hetzner.cloud)."
  type        = string
  default     = "2.22.1"
}

# ---------------------------------------------------------------------------
# etcd snapshots
#
# Snapshots are kept on each server's local disk AND uploaded to S3-compatible
# object storage. The S3 side is mandatory: local snapshots do not survive
# losing the nodes, which is the case they exist for.
# ---------------------------------------------------------------------------

variable "etcd_snapshot_schedule_cron" {
  description = "Cron spec for automatic etcd snapshots. Default: every 6 hours."
  type        = string
  default     = "0 */6 * * *"
}

variable "etcd_snapshot_retention" {
  description = "How many snapshots to keep on the local disk of each server."
  type        = number
  default     = 10
}

variable "etcd_s3_endpoint" {
  description = <<-EOT
    S3 endpoint, WITHOUT the scheme and WITHOUT the bucket name.
      DigitalOcean Spaces : fra1.digitaloceanspaces.com  (fra1 is closest to nbg1)
      Hetzner Object Store: nbg1.your-objectstorage.com
      AWS S3              : s3.eu-central-1.amazonaws.com
  EOT
  type        = string
  default     = "fra1.digitaloceanspaces.com"
}

variable "etcd_s3_region" {
  description = "S3 region. For DigitalOcean Spaces this is the datacenter slug, e.g. fra1."
  type        = string
  default     = "fra1"
}

variable "etcd_s3_bucket" {
  description = "Bucket (DigitalOcean calls it a Space) that receives etcd snapshots."
  type        = string
}

variable "etcd_s3_folder" {
  description = "Prefix inside the bucket. Defaults to the cluster name when empty."
  type        = string
  default     = ""
}

variable "etcd_s3_access_key" {
  description = "S3 access key. DigitalOcean: API -> Spaces Keys -> Generate New Key."
  type        = string
  sensitive   = true
}

variable "etcd_s3_secret_key" {
  description = "S3 secret key (shown only once when the Spaces key is created)."
  type        = string
  sensitive   = true
}

variable "etcd_s3_retention" {
  description = "How many snapshots to keep in the bucket."
  type        = number
  default     = 60
}

variable "etcd_s3_bucket_lookup_type" {
  description = <<-EOT
    How k3s addresses the bucket: "" (auto), "path" or "dns".
    Leave empty unless snapshots fail with a 404/NoSuchBucket, then try "path".
  EOT
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Local output
# ---------------------------------------------------------------------------

variable "kubeconfig_path" {
  description = "Where to write the fetched kubeconfig on your workstation."
  type        = string
  default     = "../../kubeconfig"
}

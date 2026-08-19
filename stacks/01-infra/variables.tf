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
    Source addresses allowed to reach port 22 on the nodes. Hetzner firewall
    rules take CIDR notation only, so a single address is written /32 - a bare
    "203.0.113.7" is rejected by the API.

    List as many as you need:

      ssh_allowed_cidrs = [
        "203.0.113.7/32",    # office
        "198.51.100.42/32",  # admin 1, home
        "198.51.100.99/32",  # admin 2, home
      ]

    Find your current address with: curl -s https://ifconfig.me

    This only gates SSH. kubectl is unaffected - it reaches the API through the
    load balancer, which talks to the nodes over the private network and is not
    covered by this firewall.

    Home connections usually have a changing address, so expect to update this.
    Being locked out is recoverable either way: the Hetzner Console's web console
    reaches a server regardless of firewall rules.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = alltrue([for c in var.ssh_allowed_cidrs : can(cidrnetmask(c))])
    error_message = "Every entry needs a prefix length: use \"203.0.113.7/32\" for one address, not \"203.0.113.7\"."
  }
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
    Path to an existing SSH public key. Point this at whatever key you already
    use; there is no need to generate a new one.

    OpenTofu owns the key object in Hetzner: it uploads the key, servers get it
    written into root's authorized_keys at creation, and `tofu destroy`
    removes it again. If this same public key is already in the project (Console
    -> Security -> SSH keys), delete it there first - the API rejects a second
    key with the same fingerprint (uniqueness_error). Removing a key object does
    not lock you out of running servers; it is only read when a server is
    created.
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
  description = <<-EOT
    How many snapshots to keep on the local disk of each server. Unlike the S3
    count this is per node, since each node only ever prunes its own directory:
    12 with a 6-hourly cron is 3 days on each machine.

    Local snapshots exist for fast rollback. Anything that outlives the nodes
    themselves comes from S3, which is why etcd_s3_retention is set much higher.
  EOT
  type        = number
  default     = 12
}

variable "etcd_s3_endpoint" {
  description = "Hetzner Object Storage endpoint, without the scheme or bucket name."
  type        = string
  default     = "nbg1.your-objectstorage.com"
}

variable "etcd_s3_region" {
  description = "Hetzner Object Storage location, e.g. nbg1."
  type        = string
  default     = "nbg1"
}

variable "etcd_s3_bucket" {
  description = "Private Hetzner Object Storage bucket that receives etcd snapshots."
  type        = string
}

variable "etcd_s3_folder" {
  description = "Prefix inside the bucket. Defaults to the cluster name when empty."
  type        = string
  default     = ""
}

variable "etcd_s3_access_key" {
  description = "Hetzner S3 access key (Project -> Security -> S3 credentials)."
  type        = string
  sensitive   = true
}

variable "etcd_s3_secret_key" {
  description = "Hetzner S3 secret key, shown only once when the credential pair is created."
  type        = string
  sensitive   = true
}

variable "etcd_s3_retention" {
  description = <<-EOT
    How many snapshots to keep in the bucket. k3s prunes the oldest past this
    count after every upload.

    Retention is a COUNT, not a window, and the count is shared: k3s lists every
    object under <folder>/etcd-snapshot regardless of which node wrote it, sorts
    newest-first and deletes the rest. Every server takes its own snapshot on the
    schedule, so with 3 servers and a 6-hourly cron that is 12 per day:

      days kept = etcd_s3_retention / (server_count * snapshots per day)
      360       / (3 * 4)                                        = 30 days

    Compressed snapshots of a Rancher management cluster run tens of MB, so 360
    is well within the included capacity of Hetzner Object Storage.
  EOT
  type        = number
  default     = 360
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
  description = <<-EOT
    Where to write the fetched kubeconfig, relative to this stack directory.

    It lands beside the stack that produced it, the same way stack 03 writes
    one per cluster root. Changing this replaces null_resource.kubeconfig,
    which only re-runs the fetch - it does not touch the cluster.
  EOT
  type        = string
  default     = "kubeconfig.yaml"
}

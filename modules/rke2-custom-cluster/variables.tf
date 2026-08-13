variable "config" {
  description = "Non-secret configuration for one Rancher-provisioned RKE2 cluster."
  type = object({
    cluster_name = string

    location            = optional(string, "nbg1")
    server_count        = optional(number, 3)
    server_type         = optional(string, "cx23")
    servers_are_workers = optional(bool, true)
    worker_count        = optional(number, 0)
    worker_type         = optional(string, "cx23")
    os_image            = optional(string, "ubuntu-24.04")

    ssh_key_name      = string
    ssh_allowed_cidrs = optional(list(string), ["0.0.0.0/0"])

    network_cidr = optional(string, "10.10.0.0/16")
    subnet_cidr  = optional(string, "10.10.1.0/24")
    pod_cidr     = optional(string, "10.42.0.0/16")
    service_cidr = optional(string, "10.43.0.0/16")

    load_balancer_type = optional(string, "lb11")
    api_hostname       = optional(string, "")

    rke2_version       = optional(string, "v1.35.7+rke2r1")
    cni                = optional(string, "canal")
    ingress_controller = optional(string, "traefik")

    control_plane_upgrade_concurrency = optional(string, "1")
    worker_upgrade_concurrency        = optional(string, "1")

    hcloud_ccm_version = optional(string, "1.34.0")
    hcloud_csi_version = optional(string, "2.22.1")
  })

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.config.cluster_name))
    error_message = "cluster_name must be a lowercase DNS-safe name."
  }

  validation {
    condition     = contains(["fsn1", "nbg1", "hel1", "ash", "hil", "sin"], var.config.location)
    error_message = "location must be a supported Hetzner Cloud location."
  }

  validation {
    condition     = var.config.server_count >= 3 && var.config.server_count % 2 == 1 && var.config.server_count <= 9
    error_message = "server_count must be an odd number between 3 and 9 so etcd has quorum and fits Hetzner's 10-server spread-group limit."
  }

  validation {
    condition     = var.config.worker_count >= 0 && var.config.worker_count <= 49
    error_message = "worker_count must be between 0 and 49."
  }

  validation {
    condition     = var.config.servers_are_workers || var.config.worker_count > 0
    error_message = "The cluster needs at least one worker role: enable servers_are_workers or set worker_count above zero."
  }

  validation {
    condition     = contains(["canal", "calico", "cilium", "flannel"], var.config.cni)
    error_message = "cni must be canal, calico, cilium, or flannel."
  }

  validation {
    condition     = contains(["traefik", "ingress-nginx", "none"], var.config.ingress_controller)
    error_message = "ingress_controller must be traefik, ingress-nginx, or none."
  }

  validation {
    condition     = can(cidrhost(var.config.network_cidr, 1)) && can(cidrhost(var.config.subnet_cidr, 200))
    error_message = "network_cidr and subnet_cidr must be valid, and subnet_cidr must have room for the reserved node addresses. Hetzner will also verify that the subnet is inside the network."
  }

  validation {
    condition     = alltrue([for cidr in var.config.ssh_allowed_cidrs : can(cidrnetmask(cidr))])
    error_message = "Every ssh_allowed_cidrs entry must use CIDR notation."
  }

  validation {
    condition     = length(var.config.ssh_allowed_cidrs) > 0
    error_message = "ssh_allowed_cidrs cannot be empty."
  }

  validation {
    condition     = var.config.api_hostname == "" || can(regex("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$", var.config.api_hostname))
    error_message = "api_hostname must be empty or a lowercase DNS hostname."
  }
}

variable "hcloud_token" {
  description = "Hetzner API token. Also installed as a Kubernetes Secret for the Hetzner CCM and CSI driver."
  type        = string
  sensitive   = true
}

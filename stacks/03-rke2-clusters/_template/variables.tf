variable "hcloud_token" {
  description = "Hetzner Cloud API token with Read & Write permission."
  type        = string
  sensitive   = true
}

variable "rancher_api_url" {
  description = "Rancher URL, for example https://rancher.example.com."
  type        = string

  validation {
    condition     = can(regex("^https://", var.rancher_api_url))
    error_message = "rancher_api_url must use HTTPS."
  }
}

variable "rancher_token_key" {
  description = "Complete Rancher API bearer token from Account & API Keys."
  type        = string
  sensitive   = true
}

variable "rancher_insecure" {
  description = "Skip Rancher TLS verification. Keep false for a public or trusted certificate."
  type        = bool
  default     = false
}

variable "location" {
  description = "Hetzner location for all cluster nodes and the load balancer."
  type        = string
  default     = "nbg1"
}

variable "dev" {
  description = "Create a single-node development cluster without a private network or load balancer."
  type        = bool
  default     = false
}

variable "server_count" {
  description = "Number of RKE2 server nodes. Must be an odd number between 3 and 9; ignored when dev is true."
  type        = number
  default     = 3
}

variable "server_type" {
  description = "Hetzner server type for RKE2 server nodes."
  type        = string
  default     = "cx33"
}

variable "servers_are_workers" {
  description = "Also assign the worker role to RKE2 server nodes."
  type        = bool
  default     = true
}

variable "worker_count" {
  description = "Number of dedicated RKE2 worker nodes."
  type        = number
  default     = 0
}

variable "worker_type" {
  description = "Hetzner server type for dedicated RKE2 worker nodes."
  type        = string
  default     = "cx23"
}

variable "worker_auto_location" {
  description = "Let Hetzner choose worker locations; false pins every worker to location."
  type        = bool
  default     = false
}

variable "os_image" {
  description = "Hetzner operating-system image for every node."
  type        = string
  default     = "ubuntu-24.04"
}

variable "ssh_key_name" {
  description = "Name of an existing SSH key in the Hetzner project. Stack 01 names its key <cluster_name>-admin."
  type        = string
  default     = "k3s-rancher-admin"
}

variable "ssh_allowed_cidrs" {
  description = "Public CIDRs permitted to SSH to nodes and, in dev, access the Kubernetes API."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "network_cidr" {
  description = "CIDR of the dedicated Hetzner network."
  type        = string
  default     = "10.10.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR of the node subnet inside the dedicated network."
  type        = string
  default     = "10.10.1.0/24"
}

variable "pod_cidr" {
  description = "Kubernetes pod CIDR."
  type        = string
  default     = "10.42.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes service CIDR."
  type        = string
  default     = "10.43.0.0/16"
}

variable "load_balancer_type" {
  description = "Hetzner load-balancer type for the Kubernetes API."
  type        = string
  default     = "lb11"
}

variable "api_hostname" {
  description = "Optional DNS hostname added to the Kubernetes API certificate."
  type        = string
  default     = ""
}

variable "rke2_version" {
  description = "RKE2 Kubernetes version installed by Rancher."
  type        = string
  default     = "v1.35.7+rke2r1"
}

variable "cni" {
  description = "RKE2 CNI provider."
  type        = string
  default     = "canal"
}

variable "ingress_controller" {
  description = "RKE2 ingress controller."
  type        = string
  default     = "traefik"
}

variable "kube_reserved_cpu" {
  description = "CPU reserved for Kubernetes node daemons, for example 250m. Set all five kubelet reservation variables together."
  type        = string
  default     = null

  validation {
    condition     = var.kube_reserved_cpu == null || can(regex("^[1-9][0-9]*m$", var.kube_reserved_cpu))
    error_message = "kube_reserved_cpu must use positive millicores such as \"250m\"."
  }
}

variable "kube_reserved_memory" {
  description = "Memory reserved for Kubernetes node daemons, for example 256Mi."
  type        = string
  default     = null

  validation {
    condition     = var.kube_reserved_memory == null || can(regex("^[1-9][0-9]*(Ki|Mi|Gi|Ti)$", var.kube_reserved_memory))
    error_message = "kube_reserved_memory must use a positive binary quantity such as \"256Mi\" or \"2Gi\"."
  }
}

variable "system_reserved_cpu" {
  description = "CPU reserved for operating-system daemons, for example 250m."
  type        = string
  default     = null

  validation {
    condition     = var.system_reserved_cpu == null || can(regex("^[1-9][0-9]*m$", var.system_reserved_cpu))
    error_message = "system_reserved_cpu must use positive millicores such as \"250m\"."
  }
}

variable "system_reserved_memory" {
  description = "Memory reserved for operating-system daemons and the kernel, for example 256Mi."
  type        = string
  default     = null

  validation {
    condition     = var.system_reserved_memory == null || can(regex("^[1-9][0-9]*(Ki|Mi|Gi|Ti)$", var.system_reserved_memory))
    error_message = "system_reserved_memory must use a positive binary quantity such as \"256Mi\" or \"2Gi\"."
  }
}

variable "eviction_hard_memory_available" {
  description = "Minimum node memory kept available before kubelet starts hard eviction, for example 512Mi."
  type        = string
  default     = null

  validation {
    condition     = var.eviction_hard_memory_available == null || can(regex("^[1-9][0-9]*(Ki|Mi|Gi|Ti)$", var.eviction_hard_memory_available))
    error_message = "eviction_hard_memory_available must use a positive binary quantity such as \"512Mi\" or \"1Gi\"."
  }
}

variable "kubelet_reservation_node_names" {
  description = "Optional Rancher node names that receive kubelet reservations during a staged rollout. Omit for every node."
  type        = set(string)
  default     = null

  validation {
    condition     = var.kubelet_reservation_node_names == null || length(var.kubelet_reservation_node_names) > 0
    error_message = "kubelet_reservation_node_names must be null or contain at least one node name."
  }
}

variable "cluster_agent_memory_request" {
  description = "Memory requested by each Rancher cattle-cluster-agent replica. No memory limit is imposed."
  type        = string
  default     = null

  validation {
    condition = (
      var.cluster_agent_memory_request == null ||
      can(regex("^[1-9][0-9]*(Ki|Mi|Gi|Ti)$", var.cluster_agent_memory_request))
    )
    error_message = "cluster_agent_memory_request must use a positive binary quantity such as \"1Gi\"."
  }
}

variable "control_plane_upgrade_concurrency" {
  description = "Rancher control-plane upgrade concurrency."
  type        = string
  default     = "1"
}

variable "worker_upgrade_concurrency" {
  description = "Rancher worker upgrade concurrency."
  type        = string
  default     = "1"
}

variable "drain_timeout_seconds" {
  description = "Maximum time Rancher allows each node drain so Longhorn can relocate replicas safely."
  type        = number
  default     = 1800

  validation {
    condition     = var.drain_timeout_seconds >= 1800 && floor(var.drain_timeout_seconds) == var.drain_timeout_seconds
    error_message = "drain_timeout_seconds must be a whole number of seconds and at least 1800."
  }
}

variable "control_plane_delete_empty_dir_data" {
  description = "Allow Rancher to discard emptyDir data while draining control-plane nodes."
  type        = bool
  default     = false
}

variable "worker_delete_empty_dir_data" {
  description = "Allow Rancher to discard emptyDir data while draining worker nodes."
  type        = bool
  default     = false
}

variable "hcloud_ccm_version" {
  description = "Hetzner Cloud Controller Manager chart version."
  type        = string
  default     = "1.34.0"
}

variable "hcloud_csi_version" {
  description = "Hetzner CSI driver chart version."
  type        = string
  default     = "2.22.1"
}

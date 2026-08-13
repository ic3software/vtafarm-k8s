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

variable "server_count" {
  description = "Number of RKE2 server nodes. Must be an odd number between 3 and 9."
  type        = number
  default     = 3
}

variable "server_type" {
  description = "Hetzner server type for RKE2 server nodes."
  type        = string
  default     = "cx23"
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

variable "os_image" {
  description = "Hetzner operating-system image for every node."
  type        = string
  default     = "ubuntu-24.04"
}

variable "ssh_key_name" {
  description = "Name of an existing Hetzner SSH key installed on every node."
  type        = string
  default     = "k3s-rancher-admin"
}

variable "ssh_allowed_cidrs" {
  description = "Public CIDRs permitted to SSH to the nodes."
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

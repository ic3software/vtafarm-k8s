variable "kubeconfig_path" {
  description = <<-EOT
    Kubeconfig for the downstream RKE2 cluster this stack installs into.

    Leave empty to use the file stack 03 writes for the cluster of the same
    name: ../../../03-rke2-clusters/clusters/<dir>/kubeconfig.yaml.
  EOT
  type        = string
  default     = ""
}

variable "domain" {
  description = "The zone every hostname derives from. Tenants land on vta-<name>.<domain>."
  type        = string
}

variable "frontend_host" {
  description = "Empty derives vtafarm.<domain>."
  type        = string
  default     = ""
}

variable "api_host" {
  description = "Empty derives vtafarm-api.<domain>."
  type        = string
  default     = ""
}

variable "namespace" {
  description = "Namespace the two releases install into."
  type        = string
  default     = "default"
}

variable "acme_email" {
  description = "Where Let's Encrypt sends expiry warnings."
  type        = string
}

variable "cloudflare_api_token" {
  description = "Zone -> Zone -> Read and Zone -> DNS -> Edit on the domain."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone id for the domain."
  type        = string
}

variable "did_hosting_did" {
  description = "vtafarm-api's own did:key, from `make gen-keypair` in that repo."
  type        = string
}

variable "did_hosting_private_key" {
  description = "The matching base64 ed25519 seed."
  type        = string
  sensitive   = true
}

variable "monitor_token" {
  description = "Shared secret gating /api/v1/monitor/*. Empty disables those endpoints."
  type        = string
  default     = ""
  sensitive   = true
}

variable "vtafarm_version" {
  description = "Published chart version of the frontend. Its appVersion is the image tag."
  type        = string
}

variable "vtafarm_api_version" {
  description = "Published chart version of the API."
  type        = string
}

variable "storage_class" {
  description = "For the database. Name one whose reclaimPolicy is Retain."
  type        = string
  default     = "longhorn-retain"
}

variable "traefik_namespace" {
  description = "Traefik's own namespace, where the TLSStore and the wildcard secret must live. RKE2 bundles it into kube-system."
  type        = string
  default     = "kube-system"
}

variable "cluster_ingress_ip" {
  description = "External IP of the cluster's load balancer, which tenant DNS records point at."
  type        = string
}

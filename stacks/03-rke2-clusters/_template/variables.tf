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

variable "cluster" {
  description = "Optional non-secret overrides. The directory supplies cluster_name and the module supplies other defaults."
  type        = any
}

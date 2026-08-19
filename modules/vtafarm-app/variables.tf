variable "config" {
  description = "Everything one farm needs. The cluster's platform layer (stack 04) must be installed and its Vault bootstrapped first."

  type = object({
    # The zone every hostname is derived from. Tenants land on
    # vta-<name>.<domain>; the app and the API on the two below.
    domain        = string
    frontend_host = optional(string, "")
    api_host      = optional(string, "")

    namespace = optional(string, "default")

    # Let's Encrypt sends expiry warnings here.
    acme_email = string

    # Zone -> Zone -> Read and Zone -> DNS -> Edit on the domain. cert-manager
    # solves the wildcard with it and vtafarm-api creates tenant records.
    cloudflare_api_token = string
    cloudflare_zone_id   = string

    # vtafarm-api's own identity for the DID-hosting control API, from
    # `make gen-keypair` in that repo. Not anything a daemon issued.
    did_hosting_did         = string
    did_hosting_private_key = string

    # Shared secret gating /api/v1/monitor/*. Empty disables the endpoints.
    monitor_token = optional(string, "")

    # The published versions this farm runs. Each chart's appVersion is its
    # image tag, so these two numbers pin everything.
    vtafarm_version     = string
    vtafarm_api_version = string
    chart_registry      = optional(string, "oci://ghcr.io/ic3software/charts")
    image_registry      = optional(string, "ghcr.io/ic3software")

    # Where Traefik reads its default certificate from. RKE2 bundles Traefik
    # into kube-system, and a TLSStore only works in Traefik's own namespace.
    traefik_namespace = optional(string, "kube-system")

    # Storage for the database. Name a class whose reclaimPolicy is Retain so a
    # deleted claim does not take the volume with it.
    storage_class = optional(string, "longhorn-retain")

    # The external address of the cluster's load balancer, which tenant DNS
    # records point at.
    cluster_ingress_ip = string
  })

  validation {
    condition     = can(regex("^[a-z0-9.-]+\\.[a-z]{2,}$", var.config.domain))
    error_message = "domain must be a bare DNS name, for example example.org."
  }
}

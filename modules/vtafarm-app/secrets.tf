resource "random_password" "jwt" {
  length  = 48
  special = false
}

resource "random_password" "postgres" {
  length  = 32
  special = false
}

# The database outlives the release that created it, so its password has to
# outlive a destroy too - losing it strands the volume.
resource "kubernetes_secret_v1" "postgres" {
  metadata {
    name      = "vtafarm-api-postgresql"
    namespace = var.config.namespace
  }

  data = {
    postgres-password = random_password.postgres.result
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "kubernetes_secret_v1" "api" {
  metadata {
    name      = "vtafarm-api-secrets"
    namespace = var.config.namespace
  }

  data = {
    JWT_SECRET              = random_password.jwt.result
    CLUSTER_INGRESS_IP      = var.config.cluster_ingress_ip
    CLOUDFLARE_API_TOKEN    = var.config.cloudflare_api_token
    CLOUDFLARE_ZONE_ID      = var.config.cloudflare_zone_id
    DID_HOSTING_DID         = var.config.did_hosting_did
    DID_HOSTING_PRIVATE_KEY = var.config.did_hosting_private_key
    MONITOR_TOKEN           = var.config.monitor_token
  }
}

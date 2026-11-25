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
    FARM_SIGNING_KEY        = var.config.farm_signing_key
    MONITOR_TOKEN           = var.config.monitor_token
  }
}

resource "kubernetes_secret_v1" "alertmanager_webhook" {
  count = var.config.alertmanager_webhook_enabled ? 1 : 0

  metadata {
    name      = var.config.alertmanager_webhook_secret_name
    namespace = var.config.namespace
  }

  type = "Opaque"
  data_wo = {
    ALERTMANAGER_WEBHOOK_TOKEN = var.alertmanager_webhook_token
  }
  data_wo_revision = var.config.alertmanager_webhook_token_revision

  lifecycle {
    precondition {
      condition     = length(trimspace(var.alertmanager_webhook_token)) >= 32
      error_message = "alertmanager_webhook_token must contain at least 32 characters when the webhook is enabled."
    }
  }
}

# vtafarm-api-vault is not created here. It carries the AppRole secret_id that
# scripts/vault-bootstrap.sh mints, and that must never reach OpenTofu state.
# Until it exists these pods sit in CreateContainerConfigError.
resource "helm_release" "api" {
  name      = "vtafarm-api"
  namespace = var.config.namespace

  repository = var.config.chart_registry
  chart      = "vtafarm-api"
  version    = var.config.vtafarm_api_version

  atomic  = true
  timeout = 600

  values = [yamlencode({
    image        = { repository = "${var.config.image_registry}/vtafarm-api" }
    ingress      = { host = local.api_host }
    frontendHost = local.frontend_host
    cluster      = { domain = var.config.domain }
    postgresql   = { storageClass = var.config.storage_class }
    siop = {
      rpDID                       = var.config.siop_rp_did
      challengeTTLSeconds         = tostring(var.config.siop_challenge_ttl_seconds)
      clockSkewSeconds            = tostring(var.config.siop_clock_skew_seconds)
      didResolutionTimeoutSeconds = tostring(var.config.siop_did_resolution_timeout_seconds)
      maxBodyBytes                = tostring(var.config.siop_max_body_bytes)
    }
  })]

  depends_on = [
    kubernetes_secret_v1.api,
    kubernetes_secret_v1.postgres,
    helm_release.tls,
  ]
}

resource "helm_release" "frontend" {
  name      = "vtafarm"
  namespace = var.config.namespace

  repository = var.config.chart_registry
  chart      = "vtafarm"
  version    = var.config.vtafarm_version

  atomic  = true
  timeout = 300

  values = [yamlencode({
    image   = { repository = "${var.config.image_registry}/vtafarm" }
    ingress = { host = local.frontend_host }
    api     = { url = "https://${local.api_host}" }
  })]

  depends_on = [helm_release.tls]
}

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
    vtaClaim = {
      farmDID       = var.config.farm_did
      trustTaskBase = "https://${local.api_host}/trust-task"
    }
    placement = {
      mode                   = var.config.placement.mode
      canarySessionIDs       = join(",", var.config.placement.canary_session_ids)
      greenBelowPct          = tostring(var.config.placement.green_below_percent)
      yellowBelowPct         = tostring(var.config.placement.yellow_below_percent)
      hotAtPct               = tostring(var.config.placement.hot_at_percent)
      hotObservationMin      = tostring(var.config.placement.hot_observation_minutes)
      recoveryObservationMin = tostring(var.config.placement.recovery_minutes)
      metricsStaleSeconds    = tostring(var.config.placement.metrics_stale_seconds)
      vtaP95Memory           = var.config.placement.vta_p95_memory
      pollSeconds            = tostring(var.config.placement.poll_seconds)
      workerReplicas         = var.config.placement.worker_replicas
      resources = {
        requests = {
          cpu    = var.config.placement.worker_cpu_request
          memory = var.config.placement.worker_memory_request
        }
        limits = {
          memory = var.config.placement.worker_memory_limit
        }
      }
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

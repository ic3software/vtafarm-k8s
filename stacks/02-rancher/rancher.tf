resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true

  # cert-manager's CRDs must exist before Rancher creates its Issuer.
  set = [{
    name  = "crds.enabled"
    value = "true"
  }]

  wait    = true
  timeout = 600
}

resource "random_password" "rancher_bootstrap" {
  length  = 24
  special = false
}

locals {
  rancher_bootstrap_password = coalesce(
    var.rancher_bootstrap_password,
    random_password.rancher_bootstrap.result,
  )
}

# The Rancher chart creates its own cert-manager Issuer when
# ingress.tls.source=letsEncrypt, so there is no ClusterIssuer to manage here.
resource "helm_release" "rancher" {
  name             = "rancher"
  repository       = var.rancher_chart_repo
  chart            = "rancher"
  version          = var.rancher_chart_version
  namespace        = "cattle-system"
  create_namespace = true

  set = [
    {
      name  = "hostname"
      value = var.rancher_hostname
    },
    {
      name  = "replicas"
      value = var.rancher_replicas
    },
    {
      name  = "ingress.tls.source"
      value = "letsEncrypt"
    },
    {
      name  = "agentTLSMode"
      value = "system-store"
    },
    {
      name  = "ingress.ingressClassName"
      value = var.ingress_class
    },
    {
      name  = "letsEncrypt.email"
      value = var.letsencrypt_email
    },
    {
      name  = "letsEncrypt.ingress.class"
      value = var.ingress_class
    },
    {
      name  = "letsEncrypt.environment"
      value = var.letsencrypt_environment
    },
  ]

  set_sensitive = [{
    name  = "bootstrapPassword"
    value = local.rancher_bootstrap_password
  }]

  # Rancher's own liveness depends on the ingress + certificate being ready,
  # which can take a couple of minutes on a cold cluster.
  wait    = true
  timeout = 900

  depends_on = [helm_release.cert_manager]
}

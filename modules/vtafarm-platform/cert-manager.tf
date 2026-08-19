# cert-manager on the downstream cluster. Stack 02 installs its own copy on the
# k3s management cluster; the two are unrelated, and both Vaults here need an
# issuer before their pods can mount a server certificate.
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.config.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "crds.enabled"
    value = "true"
  }

  wait    = true
  timeout = 600
}

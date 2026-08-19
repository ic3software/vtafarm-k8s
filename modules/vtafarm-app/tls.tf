resource "helm_release" "tls" {
  name      = "vtafarm-tls"
  chart     = "${path.module}/charts/vtafarm-tls"
  namespace = var.config.traefik_namespace

  values = [yamlencode({
    domain               = var.config.domain
    acmeEmail            = var.config.acme_email
    traefikNamespace     = var.config.traefik_namespace
    wildcardSecret       = local.wildcard_secret
    cloudflareApiToken   = var.config.cloudflare_api_token
    certManagerNamespace = "cert-manager"
  })]
}

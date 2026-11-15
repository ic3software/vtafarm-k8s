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

  set = [{
    name  = "crds.enabled"
    value = "true"
  }]

  wait    = true
  timeout = 600
}

# The farm Vault uses an internal CA which application pods cannot trust from
# their image's public root store. trust-manager reads a public-only ConfigMap
# in its own namespace and publishes that CA in farm-managed namespaces.
resource "helm_release" "trust_manager" {
  name      = "trust-manager"
  chart     = "oci://quay.io/jetstack/charts/trust-manager"
  version   = var.config.trust_manager_version
  namespace = helm_release.cert_manager.namespace

  values = [yamlencode({
    # This deployment distributes only the private-PKI Vault root certificate. Avoid loading an
    # unrelated public CA package which no Bundle consumes.
    defaultPackage = {
      enabled = false
    }
    app = {
      trust = {
        namespace = "cert-manager"
      }
    }
  })]

  wait    = true
  timeout = 300

  depends_on = [helm_release.cert_manager]
}

locals {
  vault_ca_bundle     = var.config.vault_ca_bundle
  has_vault_ca_bundle = local.vault_ca_bundle != null
}

# This contains public certificates only. Keeping it separate from vault-ca
# prevents trust-manager from receiving RBAC to read CA keys or other secrets.
resource "kubernetes_config_map_v1" "vault_trust_source" {
  count = local.has_vault_ca_bundle ? 1 : 0

  metadata {
    name      = "vtafarm-vault-trust-source"
    namespace = helm_release.cert_manager.namespace
  }

  data = {
    "ca.crt" = local.vault_ca_bundle
  }
}

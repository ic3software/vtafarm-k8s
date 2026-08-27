resource "kubernetes_namespace" "transit" {
  metadata {
    name = var.config.transit_namespace
  }

  # Rancher's namespace controller keeps rewriting its own annotations; leave them to it.
  lifecycle {
    ignore_changes = [metadata[0].annotations]
  }
}

resource "helm_release" "vault_transit_pki" {
  name      = "vault-transit-pki"
  chart     = "${path.module}/charts/vault-pki"
  namespace = kubernetes_namespace.transit.metadata[0].name

  values = [yamlencode({
    name         = "vault-transit"
    caCommonName = "vtafarm-vault-transit-ca"
    commonName   = "vault-transit.${var.config.transit_namespace}.svc.cluster.local"
    dnsNames = [
      "localhost",
      "vault-transit",
      "vault-transit.${var.config.transit_namespace}",
      "vault-transit.${var.config.transit_namespace}.svc",
      "vault-transit.${var.config.transit_namespace}.svc.cluster.local",
    ]
    networkPolicy = {
      enabled            = true
      allowFromNamespace = var.config.vault_namespace
      port               = 8200
    }
  })]

  wait    = true
  timeout = 300

  depends_on = [helm_release.cert_manager]
}

# wait = false is deliberate here and on the farm release below. A freshly
# installed Vault comes up sealed, and a sealed Vault reports NOT ready by
# design - it is waiting for `vault operator init`, which is the next step and
# cannot happen until this apply returns. With wait = true the apply would hang
# until the timeout and then roll back a Vault that was doing exactly the right
# thing.
resource "helm_release" "vault_transit" {
  name       = "vault-transit"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = var.config.vault_chart_version
  namespace  = kubernetes_namespace.transit.metadata[0].name

  values = [templatefile("${path.module}/templates/vault-transit-values.yaml.tftpl", {
    namespace     = var.config.transit_namespace
    data_size     = var.config.transit_data_size
    storage_class = var.config.storage_class
  })]

  wait = false

  depends_on = [
    helm_release.vault_transit_pki,
    helm_release.longhorn,
  ]
}

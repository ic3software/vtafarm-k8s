resource "kubernetes_namespace" "vault" {
  metadata {
    name = var.config.vault_namespace
  }
}

resource "helm_release" "vault_pki" {
  name      = "vault-pki"
  chart     = "${path.module}/charts/vault-pki"
  namespace = kubernetes_namespace.vault.metadata[0].name

  values = [yamlencode({
    name         = "vault"
    caCommonName = "vtafarm-vault-ca"
    commonName   = "vault.${var.config.vault_namespace}.svc.cluster.local"
    # Covers the client service, the active/standby services, the per-pod Raft
    # peers, and localhost for the CLI running inside the pod.
    dnsNames = [
      "localhost",
      "vault",
      "vault.${var.config.vault_namespace}",
      "vault.${var.config.vault_namespace}.svc",
      "vault.${var.config.vault_namespace}.svc.cluster.local",
      "vault-active",
      "vault-active.${var.config.vault_namespace}",
      "vault-active.${var.config.vault_namespace}.svc",
      "vault-active.${var.config.vault_namespace}.svc.cluster.local",
      "*.vault-internal",
      "*.vault-internal.${var.config.vault_namespace}.svc.cluster.local",
    ]
  })]

  wait    = true
  timeout = 300

  depends_on = [helm_release.cert_manager]
}

# Depends on the transit release, not on its bootstrap: the `vault-transit-token`
# secret is minted by a human running scripts/vault-bootstrap.sh, which needs a
# root token that must never reach OpenTofu state. These pods therefore come up
# in CreateContainerConfigError and settle once that secret exists.
resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = var.config.vault_chart_version
  namespace  = kubernetes_namespace.vault.metadata[0].name

  values = [templatefile("${path.module}/templates/vault-values.yaml.tftpl", {
    namespace         = var.config.vault_namespace
    transit_namespace = var.config.transit_namespace
    chart_version     = var.config.vault_chart_version
    replicas          = var.config.vault_replicas
    data_size         = var.config.vault_data_size
    audit_size        = var.config.vault_audit_size
    storage_class     = var.config.storage_class
  })]

  wait = false

  depends_on = [
    helm_release.vault_pki,
    helm_release.vault_transit,
    helm_release.longhorn,
  ]
}

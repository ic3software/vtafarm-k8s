locals {
  # The directory name is the source of truth, exactly as in stack 03 - and it
  # must match the RKE2 cluster's directory there, because that is where this
  # root reads the kubeconfig from.
  cluster_name = basename(abspath(path.root)) == "_template" ? "template" : basename(abspath(path.root))

  kubeconfig_path = coalesce(
    var.kubeconfig_path,
    "../../../03-rke2-clusters/clusters/${local.cluster_name}/kubeconfig.yaml",
  )
}

module "platform" {
  source = "../../../modules/vtafarm-platform"

  config = {
    cluster_name = local.cluster_name

    cert_manager_version = var.cert_manager_version

    longhorn_version       = var.longhorn_version
    longhorn_replica_count = var.longhorn_replica_count
    longhorn_default_class = var.longhorn_default_class

    vault_chart_version = var.vault_chart_version
    vault_namespace     = var.vault_namespace
    vault_replicas      = var.vault_replicas
    vault_data_size     = var.vault_data_size
    vault_audit_size    = var.vault_audit_size

    transit_namespace = var.transit_namespace
    transit_data_size = var.transit_data_size

    storage_class = var.storage_class
  }
}

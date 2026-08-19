locals {
  # The directory name is the source of truth, exactly as in stacks 03 and 04 -
  # and it must match the RKE2 cluster's directory there, because that is where
  # this root reads the kubeconfig from.
  cluster_name = basename(abspath(path.root)) == "_template" ? "template" : basename(abspath(path.root))

  kubeconfig_path = coalesce(
    var.kubeconfig_path,
    "../../../03-rke2-clusters/clusters/${local.cluster_name}/kubeconfig.yaml",
  )
}

module "app" {
  source = "../../../modules/vtafarm-app"

  config = {
    domain        = var.domain
    frontend_host = var.frontend_host
    api_host      = var.api_host
    namespace     = var.namespace

    acme_email           = var.acme_email
    cloudflare_api_token = var.cloudflare_api_token
    cloudflare_zone_id   = var.cloudflare_zone_id

    did_hosting_did         = var.did_hosting_did
    did_hosting_private_key = var.did_hosting_private_key
    monitor_token           = var.monitor_token

    vtafarm_version     = var.vtafarm_version
    vtafarm_api_version = var.vtafarm_api_version

    storage_class      = var.storage_class
    traefik_namespace  = var.traefik_namespace
    cluster_ingress_ip = var.cluster_ingress_ip
  }
}

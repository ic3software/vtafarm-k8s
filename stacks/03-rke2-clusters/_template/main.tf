module "rke2" {
  source = "../../../modules/rke2-custom-cluster"

  # The directory name is the source of truth for the Rancher cluster name.
  config = {
    cluster_name                      = basename(abspath(path.root)) == "_template" ? "template" : basename(abspath(path.root))
    location                          = var.location
    server_count                      = var.server_count
    server_type                       = var.server_type
    servers_are_workers               = var.servers_are_workers
    worker_count                      = var.worker_count
    worker_type                       = var.worker_type
    os_image                          = var.os_image
    ssh_key_name                      = var.ssh_key_name
    ssh_allowed_cidrs                 = var.ssh_allowed_cidrs
    network_cidr                      = var.network_cidr
    subnet_cidr                       = var.subnet_cidr
    pod_cidr                          = var.pod_cidr
    service_cidr                      = var.service_cidr
    load_balancer_type                = var.load_balancer_type
    api_hostname                      = var.api_hostname
    rke2_version                      = var.rke2_version
    cni                               = var.cni
    ingress_controller                = var.ingress_controller
    control_plane_upgrade_concurrency = var.control_plane_upgrade_concurrency
    worker_upgrade_concurrency        = var.worker_upgrade_concurrency
    hcloud_ccm_version                = var.hcloud_ccm_version
    hcloud_csi_version                = var.hcloud_csi_version
  }

  hcloud_token = var.hcloud_token
}

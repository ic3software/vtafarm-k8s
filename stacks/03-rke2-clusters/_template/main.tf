module "rke2" {
  source = "../../../modules/rke2-custom-cluster"

  # The directory name is the source of truth for the Rancher cluster name.
  config = {
    cluster_name                        = basename(abspath(path.root)) == "_template" ? "template" : basename(abspath(path.root))
    location                            = var.location
    dev                                 = var.dev
    server_count                        = var.server_count
    server_type                         = var.server_type
    servers_are_workers                 = var.servers_are_workers
    worker_count                        = var.worker_count
    worker_type                         = var.worker_type
    os_image                            = var.os_image
    ssh_key_name                        = var.ssh_key_name
    ssh_allowed_cidrs                   = var.ssh_allowed_cidrs
    network_cidr                        = var.network_cidr
    subnet_cidr                         = var.subnet_cidr
    pod_cidr                            = var.pod_cidr
    service_cidr                        = var.service_cidr
    load_balancer_type                  = var.load_balancer_type
    api_hostname                        = var.api_hostname
    rke2_version                        = var.rke2_version
    cni                                 = var.cni
    ingress_controller                  = var.ingress_controller
    kube_reserved_cpu                   = var.kube_reserved_cpu
    kube_reserved_memory                = var.kube_reserved_memory
    system_reserved_cpu                 = var.system_reserved_cpu
    system_reserved_memory              = var.system_reserved_memory
    eviction_hard_memory_available      = var.eviction_hard_memory_available
    kubelet_reservation_node_names      = var.kubelet_reservation_node_names
    cluster_agent_memory_request        = var.cluster_agent_memory_request
    control_plane_upgrade_concurrency   = var.control_plane_upgrade_concurrency
    worker_upgrade_concurrency          = var.worker_upgrade_concurrency
    drain_timeout_seconds               = var.drain_timeout_seconds
    control_plane_delete_empty_dir_data = var.control_plane_delete_empty_dir_data
    worker_delete_empty_dir_data        = var.worker_delete_empty_dir_data
    hcloud_ccm_version                  = var.hcloud_ccm_version
    hcloud_csi_version                  = var.hcloud_csi_version
  }

  hcloud_token = var.hcloud_token
}

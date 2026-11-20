output "cluster_id" {
  description = "Rancher provisioning cluster ID."
  value       = rancher2_cluster_v2.this.id
}

output "cluster_v1_id" {
  description = "Rancher management API v1 cluster ID."
  value       = rancher2_cluster_v2.this.cluster_v1_id
}

output "kubernetes_api_endpoint" {
  description = "Direct RKE2 API endpoint through the load balancer, or the node in dev."
  value = "https://${var.config.api_hostname != "" ? var.config.api_hostname : (
    var.config.dev ? hcloud_primary_ip.dev_api[0].ip_address : hcloud_load_balancer.api[0].ipv4
  )}:6443"
}

output "load_balancer_ipv4" {
  description = "Public IPv4 of the RKE2 API load balancer; null in dev."
  value       = var.config.dev ? null : hcloud_load_balancer.api[0].ipv4
}

output "development_mode" {
  description = "Whether this cluster intentionally runs without a load balancer and may retire down to one control-plane node."
  value       = var.config.dev
}

output "control_plane_delete_empty_dir_data" {
  description = "Whether control-plane retirement may discard emptyDir data."
  value       = var.config.control_plane_delete_empty_dir_data
}

output "worker_delete_empty_dir_data" {
  description = "Whether worker retirement may discard emptyDir data."
  value       = var.config.worker_delete_empty_dir_data
}

output "nodes" {
  description = "RKE2 node names, classes, pools, types, roles, locations, and addresses."
  value = {
    for key, server in hcloud_server.node : key => {
      name        = server.name
      node_class  = local.nodes[key].node_class
      pool        = local.nodes[key].pool
      server_type = server.server_type
      roles       = local.nodes[key].roles
      location    = server.location
      public_ip   = server.ipv4_address
      private_ip  = one(server.network).ip
    } if contains(keys(local.nodes), key)
  }
}

output "kube_config" {
  description = "Rancher-generated kubeconfig. It becomes available after the cluster connects."
  value       = rancher2_cluster_v2.this.kube_config
  sensitive   = true
}

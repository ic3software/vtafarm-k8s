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
    var.config.dev ? hcloud_server.node["server-1"].ipv4_address : hcloud_load_balancer.api[0].ipv4
  )}:6443"
}

output "load_balancer_ipv4" {
  description = "Public IPv4 of the RKE2 API load balancer; null in dev."
  value       = var.config.dev ? null : hcloud_load_balancer.api[0].ipv4
}

output "nodes" {
  description = "RKE2 node names, roles, and addresses."
  value = {
    for key, server in hcloud_server.node : key => {
      name       = server.name
      roles      = local.nodes[key].roles
      public_ip  = server.ipv4_address
      private_ip = local.nodes[key].private_ip
    }
  }
}

output "kube_config" {
  description = "Rancher-generated kubeconfig. It becomes available after the cluster connects."
  value       = rancher2_cluster_v2.this.kube_config
  sensitive   = true
}

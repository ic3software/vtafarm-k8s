output "cluster_id" {
  value = module.rke2.cluster_id
}

output "cluster_v1_id" {
  value = module.rke2.cluster_v1_id
}

output "kubernetes_api_endpoint" {
  value = module.rke2.kubernetes_api_endpoint
}

output "load_balancer_ipv4" {
  value = module.rke2.load_balancer_ipv4
}

output "development_mode" {
  value = module.rke2.development_mode
}

output "control_plane_delete_empty_dir_data" {
  value = module.rke2.control_plane_delete_empty_dir_data
}

output "worker_delete_empty_dir_data" {
  value = module.rke2.worker_delete_empty_dir_data
}

output "nodes" {
  value = module.rke2.nodes
}

output "kube_config" {
  description = "Read after Rancher reports Active: tofu output -raw kube_config > kubeconfig.yaml"
  value       = module.rke2.kube_config
  sensitive   = true
}

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

output "nodes" {
  value = module.rke2.nodes
}

output "kube_config" {
  description = "Read after Rancher reports Active: terraform output -raw kube_config > kubeconfig.yaml"
  value       = module.rke2.kube_config
  sensitive   = true
}

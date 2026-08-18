output "vault_namespace" {
  description = "Namespace holding the farm Vault."
  value       = kubernetes_namespace.vault.metadata[0].name
}

output "transit_namespace" {
  description = "Namespace holding the transit Vault that the farm auto-unseals against."
  value       = kubernetes_namespace.transit.metadata[0].name
}

output "vault_address" {
  description = "In-cluster address vtafarm-api and the tenant pods use to reach Vault."
  value       = "https://vault.${var.config.vault_namespace}.svc:8200"
}

output "vault_replicas" {
  description = "Raft peer count. Each peer needs its own node: the chart's pod anti-affinity is hard."
  value       = var.config.vault_replicas
}

output "storage_class" {
  description = "StorageClass backing the Vault volumes."
  value       = var.config.storage_class
}

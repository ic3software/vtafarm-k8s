output "vault_namespace" {
  value = module.platform.vault_namespace
}

output "transit_namespace" {
  value = module.platform.transit_namespace
}

output "vault_address" {
  description = "Set this as VAULT_ADDR for vtafarm-api and the tenant pods."
  value       = module.platform.vault_address
}

output "vault_replicas" {
  value = module.platform.vault_replicas
}

output "storage_class" {
  value = module.platform.storage_class
}

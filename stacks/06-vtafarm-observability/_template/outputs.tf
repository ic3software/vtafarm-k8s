output "enabled" {
  value = module.observability.enabled
}

output "namespace" {
  value = module.observability.namespace
}

output "prometheus_url" {
  value = module.observability.prometheus_url
}

output "grafana_url" {
  value = module.observability.grafana_url
}

output "storage_class_name" {
  value = module.observability.storage_class_name
}

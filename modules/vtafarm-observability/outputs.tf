output "enabled" {
  value = var.config.enabled
}

output "namespace" {
  value = var.config.enabled ? var.config.namespace : null
}

output "prometheus_url" {
  description = "Private in-cluster Prometheus URL for vtafarm-api."
  value       = var.config.enabled ? "http://${local.release_name}-prometheus.${var.config.namespace}.svc:9090" : null
}

output "grafana_url" {
  description = "Private in-cluster Grafana URL; use kubectl port-forward for operator access."
  value       = var.config.enabled && var.config.grafana_enabled ? "http://${local.release_name}-grafana.${var.config.namespace}.svc:80" : null
}

output "storage_class_name" {
  value = var.config.enabled ? var.config.storage_class_name : null
}

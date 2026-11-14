output "enabled" {
  value = var.config.enabled
}

output "namespace" {
  value = var.config.enabled ? var.config.namespace : null
}

output "prometheus_url" {
  description = "Private in-cluster URL for the local Prometheus instance."
  value       = var.config.enabled ? local.prometheus_url : null
}

output "thanos_query_url" {
  description = "Private in-cluster Thanos Query URL for live and object-storage metrics."
  value       = var.config.enabled && var.config.thanos_enabled ? local.thanos_query_url : null
}

output "thanos_s3_prefix" {
  description = "Object prefix used for this cluster's Thanos blocks."
  value       = var.config.enabled && var.config.thanos_enabled ? local.thanos_s3_prefix : null
}

output "metrics_query_url" {
  description = "Private Prometheus-compatible query URL for vtafarm-api."
  value       = var.config.enabled ? (var.config.thanos_enabled ? local.thanos_query_url : local.prometheus_url) : null
}

output "grafana_url" {
  description = "Private in-cluster Grafana URL; use kubectl port-forward for operator access."
  value       = var.config.enabled && var.config.grafana_enabled ? "http://${local.release_name}-grafana.${var.config.namespace}.svc:80" : null
}

output "storage_class_name" {
  value = var.config.enabled ? var.config.storage_class_name : null
}

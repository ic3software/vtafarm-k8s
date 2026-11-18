output "enabled" {
  value = var.config.enabled
}

output "namespace" {
  value = var.config.enabled ? var.config.namespace : null
}

output "loki_namespace" {
  description = "Namespace containing Loki, its gateway, Alloy, and logging credentials."
  value       = var.config.enabled && var.config.loki_enabled ? var.config.loki_namespace : null
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
  value       = var.config.enabled ? (var.config.thanos_enabled ? local.thanos_query_frontend_url : local.prometheus_url) : null
}

output "grafana_url" {
  description = "Private in-cluster Grafana URL; use kubectl port-forward for operator access."
  value       = var.config.enabled && var.config.grafana_enabled ? "http://${local.release_name}-grafana.${var.config.namespace}.svc:80" : null
}

output "loki_gateway_url" {
  description = "Private in-cluster Loki gateway URL used by Alloy and Grafana."
  value       = var.config.enabled && var.config.loki_enabled ? local.loki_gateway_url : null
}

output "loki_s3_buckets" {
  description = "Private object-storage locations used for Loki chunks/indexes and ruler data."
  value = var.config.enabled && var.config.loki_enabled ? {
    chunks = {
      bucket = var.config.loki_s3_chunks_bucket
      prefix = var.config.loki_s3_chunks_prefix
    }
    ruler = {
      bucket = var.config.loki_s3_ruler_bucket
      prefix = var.config.loki_s3_ruler_prefix
    }
  } : null
}

output "storage_class_name" {
  value = var.config.enabled ? var.config.storage_class_name : null
}

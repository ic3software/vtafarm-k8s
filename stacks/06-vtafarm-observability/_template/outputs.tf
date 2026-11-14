output "enabled" {
  value = module.observability.enabled
}

output "namespace" {
  value = module.observability.namespace
}

output "prometheus_url" {
  value = module.observability.prometheus_url
}

output "thanos_query_url" {
  value = module.observability.thanos_query_url
}

output "thanos_s3_prefix" {
  value = module.observability.thanos_s3_prefix
}

output "metrics_query_url" {
  value = module.observability.metrics_query_url
}

output "grafana_url" {
  value = module.observability.grafana_url
}

output "storage_class_name" {
  value = module.observability.storage_class_name
}

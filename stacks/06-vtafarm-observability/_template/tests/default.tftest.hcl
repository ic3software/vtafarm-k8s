mock_provider "helm" {}
mock_provider "kubernetes" {}

run "enabled_with_sensitive_credentials" {
  command = plan

  variables {
    observability_enabled          = true
    thanos_s3_bucket               = "vtafarm-thanos-test"
    thanos_s3_prefix               = "observability/production/metrics"
    thanos_s3_endpoint             = "nbg1.your-objectstorage.com"
    thanos_s3_region               = "nbg1"
    thanos_s3_access_key           = "test-access-key"
    thanos_s3_secret_key           = "test-secret-key"
    thanos_query_frontend_replicas = 3
    loki_replicas                  = 3
    loki_gateway_replicas          = 2
    loki_storage_size              = "20Gi"
  }

  assert {
    condition     = output.metrics_query_url == "http://thanos-query-frontend.monitoring.svc:9090"
    error_message = "The stack must expose Thanos Query Frontend as its Prometheus-compatible endpoint."
  }

  assert {
    condition     = output.thanos_s3_prefix == "observability/production/metrics"
    error_message = "The stack must pass the configured object prefix to Thanos."
  }

  assert {
    condition = (
      var.loki_replicas == 3 &&
      var.loki_gateway_replicas == 2 &&
      var.loki_storage_size == "20Gi" &&
      var.thanos_query_frontend_replicas == 3
    )
    error_message = "The explicit staging/production settings must select three Loki replicas, two gateways, and 20Gi per replica."
  }

  assert {
    condition = (
      output.logging_namespace == "logging" &&
      output.loki_gateway_url == "http://loki-gateway.logging.svc" &&
      output.loki_s3_buckets.chunks.bucket == "loki" &&
      output.loki_s3_buckets.chunks.prefix == "template-loki-chunks" &&
      output.loki_s3_buckets.ruler.bucket == "loki" &&
      output.loki_s3_buckets.ruler.prefix == "template-loki-ruler"
    )
    error_message = "The stack must place logging in its own namespace, expose the private gateway, and derive cluster-scoped S3 locations."
  }
}

run "explicit_development_logging_topology" {
  command = plan

  variables {
    observability_enabled = true
    thanos_enabled        = false
    loki_replicas         = 1
    loki_gateway_replicas = 1
    loki_storage_size     = "10Gi"
    loki_s3_endpoint      = "nbg1.your-objectstorage.com"
    loki_s3_region        = "nbg1"
    loki_s3_access_key    = "test-access-key"
    loki_s3_secret_key    = "test-secret-key"
  }

  assert {
    condition = (
      var.loki_replicas == 1 &&
      var.loki_gateway_replicas == 1 &&
      var.loki_storage_size == "10Gi" &&
      var.loki_storage_class == "hcloud-volumes-retain"
    )
    error_message = "Development settings must select one Loki replica, one gateway, and a retained 10Gi Hetzner Volume."
  }
}

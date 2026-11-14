mock_provider "helm" {}
mock_provider "kubernetes" {}

run "enabled_with_sensitive_credentials" {
  command = plan

  variables {
    observability_enabled = true
    thanos_s3_bucket      = "vtafarm-thanos-test"
    thanos_s3_prefix      = "observability/production/metrics"
    thanos_s3_endpoint    = "nbg1.your-objectstorage.com"
    thanos_s3_region      = "nbg1"
    thanos_s3_access_key  = "test-access-key"
    thanos_s3_secret_key  = "test-secret-key"
  }

  assert {
    condition     = output.metrics_query_url == "http://thanos-query.monitoring.svc:9090"
    error_message = "The stack must expose Thanos Query as its Prometheus-compatible endpoint."
  }

  assert {
    condition     = output.thanos_s3_prefix == "observability/production/metrics"
    error_message = "The stack must pass the configured object prefix to Thanos."
  }
}

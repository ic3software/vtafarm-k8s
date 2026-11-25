locals {
  cluster_name = basename(abspath(path.root)) == "_template" ? "template" : basename(abspath(path.root))

  kubeconfig_path = coalesce(
    var.kubeconfig_path,
    "../../../03-rke2-clusters/clusters/${local.cluster_name}/kubeconfig.yaml",
  )

  loki_s3_chunks_bucket = var.loki_s3_chunks_bucket != "" ? var.loki_s3_chunks_bucket : "loki"
  loki_s3_ruler_bucket  = var.loki_s3_ruler_bucket != "" ? var.loki_s3_ruler_bucket : "loki"
  loki_s3_chunks_prefix = "${local.cluster_name}-loki-chunks"
  loki_s3_ruler_prefix  = "${local.cluster_name}-loki-ruler"
  loki_s3_endpoint      = var.loki_s3_endpoint != "" ? var.loki_s3_endpoint : var.thanos_s3_endpoint
  loki_s3_region        = var.loki_s3_region != "" ? var.loki_s3_region : var.thanos_s3_region
  loki_s3_access_key    = var.loki_s3_access_key != "" ? var.loki_s3_access_key : var.thanos_s3_access_key
  loki_s3_secret_key    = var.loki_s3_secret_key != "" ? var.loki_s3_secret_key : var.thanos_s3_secret_key
}

module "observability" {
  source = "../../../modules/vtafarm-observability"

  config = {
    cluster_name = local.cluster_name

    enabled              = var.observability_enabled
    monitoring_namespace = var.monitoring_namespace
    logging_namespace    = var.logging_namespace
    chart_version        = var.kube_prometheus_stack_version

    storage_class_name        = var.prometheus_storage_class
    prometheus_storage_size   = var.prometheus_storage_size
    prometheus_retention      = var.prometheus_retention
    prometheus_retention_size = var.prometheus_retention_size
    scrape_interval           = var.prometheus_scrape_interval
    evaluation_interval       = var.prometheus_evaluation_interval

    prometheus_replicas       = var.prometheus_replicas
    prometheus_cpu_request    = var.prometheus_cpu_request
    prometheus_cpu_limit      = var.prometheus_cpu_limit
    prometheus_memory_request = var.prometheus_memory_request
    prometheus_memory_limit   = var.prometheus_memory_limit

    thanos_enabled                    = var.thanos_enabled
    thanos_chart_version              = var.thanos_chart_version
    thanos_s3_bucket                  = var.thanos_s3_bucket
    thanos_s3_prefix                  = var.thanos_s3_prefix
    thanos_s3_endpoint                = var.thanos_s3_endpoint
    thanos_s3_region                  = var.thanos_s3_region
    thanos_s3_access_key              = var.thanos_s3_access_key
    thanos_s3_secret_key              = var.thanos_s3_secret_key
    thanos_retention                  = var.thanos_retention
    thanos_query_replicas             = var.thanos_query_replicas
    thanos_query_frontend_replicas    = var.thanos_query_frontend_replicas
    thanos_storegateway_replicas      = var.thanos_storegateway_replicas
    thanos_storegateway_storage_class = var.thanos_storegateway_storage_class
    thanos_storegateway_storage_size  = var.thanos_storegateway_storage_size
    thanos_compactor_storage_class    = var.thanos_compactor_storage_class
    thanos_compactor_storage_size     = var.thanos_compactor_storage_size

    loki_enabled          = var.loki_enabled
    loki_chart_version    = var.loki_chart_version
    alloy_chart_version   = var.alloy_chart_version
    loki_replicas         = var.loki_replicas
    loki_gateway_replicas = var.loki_gateway_replicas
    loki_storage_class    = var.loki_storage_class
    loki_storage_size     = var.loki_storage_size
    loki_retention        = var.loki_retention
    loki_s3_chunks_bucket = local.loki_s3_chunks_bucket
    loki_s3_ruler_bucket  = local.loki_s3_ruler_bucket
    loki_s3_chunks_prefix = local.loki_s3_chunks_prefix
    loki_s3_ruler_prefix  = local.loki_s3_ruler_prefix
    loki_s3_endpoint      = local.loki_s3_endpoint
    loki_s3_region        = local.loki_s3_region
    loki_s3_access_key    = local.loki_s3_access_key
    loki_s3_secret_key    = local.loki_s3_secret_key

    grafana_enabled                     = var.grafana_enabled
    alertmanager_enabled                = var.alertmanager_enabled
    alertmanager_replicas               = var.alertmanager_replicas
    alertmanager_webhook_enabled        = var.alertmanager_webhook_enabled
    alertmanager_webhook_url            = var.alertmanager_webhook_url
    alertmanager_webhook_secret_name    = var.alertmanager_webhook_secret_name
    alertmanager_webhook_token_revision = var.alertmanager_webhook_token_revision
  }

  alertmanager_webhook_token = var.alertmanager_webhook_token
}

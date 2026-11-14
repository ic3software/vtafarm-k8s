locals {
  cluster_name = basename(abspath(path.root)) == "_template" ? "template" : basename(abspath(path.root))

  kubeconfig_path = coalesce(
    var.kubeconfig_path,
    "../../../03-rke2-clusters/clusters/${local.cluster_name}/kubeconfig.yaml",
  )
}

module "observability" {
  source = "../../../modules/vtafarm-observability"

  config = {
    cluster_name = local.cluster_name

    enabled       = var.observability_enabled
    namespace     = var.observability_namespace
    chart_version = var.kube_prometheus_stack_version

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

    thanos_enabled                   = var.thanos_enabled
    thanos_chart_version             = var.thanos_chart_version
    thanos_image_version             = var.thanos_image_version
    thanos_s3_bucket                 = var.thanos_s3_bucket
    thanos_s3_prefix                 = var.thanos_s3_prefix
    thanos_s3_endpoint               = var.thanos_s3_endpoint
    thanos_s3_region                 = var.thanos_s3_region
    thanos_s3_access_key             = var.thanos_s3_access_key
    thanos_s3_secret_key             = var.thanos_s3_secret_key
    thanos_retention                 = var.thanos_retention
    thanos_query_replicas            = var.thanos_query_replicas
    thanos_storegateway_replicas     = var.thanos_storegateway_replicas
    thanos_storegateway_storage_size = var.thanos_storegateway_storage_size
    thanos_compactor_storage_size    = var.thanos_compactor_storage_size

    grafana_enabled      = var.grafana_enabled
    alertmanager_enabled = var.alertmanager_enabled
  }
}

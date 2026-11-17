mock_provider "helm" {}
mock_provider "kubernetes" {}

run "disabled_by_default" {
  command = plan

  variables {
    config = {
      cluster_name = "rke2-vtafarm-staging"
    }
  }

  assert {
    condition = (
      length(helm_release.kube_prometheus_stack) == 0 &&
      length(helm_release.thanos) == 0 &&
      length(kubernetes_namespace_v1.monitoring) == 0 &&
      length(kubernetes_secret_v1.thanos_objstore) == 0 &&
      length(kubernetes_storage_class_v1.hcloud_volumes_retain) == 0
    )
    error_message = "Observability must create no resources unless explicitly enabled."
  }
}

run "prometheus_on_retained_hcloud_volume" {
  command = plan

  variables {
    config = {
      cluster_name         = "rke2-vtafarm-production"
      enabled              = true
      thanos_s3_bucket     = "vtafarm-thanos-test"
      thanos_s3_prefix     = "observability/production/metrics"
      thanos_s3_endpoint   = "nbg1.your-objectstorage.com"
      thanos_s3_region     = "nbg1"
      thanos_s3_access_key = "test-access-key"
      thanos_s3_secret_key = "test-secret-key"
    }
  }

  assert {
    condition = (
      kubernetes_storage_class_v1.hcloud_volumes_retain[0].storage_provisioner == "csi.hetzner.cloud" &&
      kubernetes_storage_class_v1.hcloud_volumes_retain[0].reclaim_policy == "Retain" &&
      kubernetes_storage_class_v1.hcloud_volumes_retain[0].volume_binding_mode == "WaitForFirstConsumer"
    )
    error_message = "Prometheus storage must use a retained, topology-aware Hetzner Cloud Volume."
  }

  assert {
    condition = (
      helm_release.kube_prometheus_stack[0].name == "monitoring" &&
      helm_release.kube_prometheus_stack[0].version == "93.2.2" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).alertmanager.enabled == false &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).grafana.enabled == true &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.retention == "30d" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.retentionSize == "40GB" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.replicas == 1 &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.externalLabels.cluster == "rke2-vtafarm-production" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.thanos.objectStorageConfig.existingSecret.name == "thanos-objstore" &&
      !contains(keys(yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.thanos), "image") &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues == false &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.thanosService.enabled == true &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).grafana.sidecar.datasources.url == "http://thanos-query-frontend.monitoring.svc:9090" &&
      !contains(keys(yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.resources.limits), "cpu") &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName == "hcloud-volumes-retain" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage == "50Gi"
    )
    error_message = "Prometheus must keep bounded history on the configured Hetzner Volume."
  }

  assert {
    condition = (
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).kubelet.serviceMonitor.resource == true &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).kubelet.serviceMonitor.resourcePath == "/metrics/resource" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).kubelet.serviceMonitor.resourceInterval == "30s"
    )
    error_message = "Prometheus must scrape kubelet node-resource metrics at the configured interval."
  }

  assert {
    condition = (
      length(kubernetes_secret_v1.thanos_objstore) == 1 &&
      kubernetes_secret_v1.thanos_objstore[0].metadata[0].name == "thanos-objstore" &&
      yamldecode(kubernetes_secret_v1.thanos_objstore[0].data["objstore.yml"]).prefix == "observability/production/metrics" &&
      helm_release.thanos[0].name == "thanos" &&
      helm_release.thanos[0].version == "0.49.0" &&
      !contains(keys(yamldecode(helm_release.thanos[0].values[0]).global), "image") &&
      yamldecode(helm_release.thanos[0].values[0]).global.storageClass == "hcloud-volumes-retain" &&
      yamldecode(helm_release.thanos[0].values[0]).receive.enabled == false &&
      yamldecode(helm_release.thanos[0].values[0]).query.replicaCount == 2 &&
      yamldecode(helm_release.thanos[0].values[0]).queryFrontend.enabled == true &&
      yamldecode(helm_release.thanos[0].values[0]).queryFrontend.replicaCount == 2 &&
      yamldecode(helm_release.thanos[0].values[0]).queryFrontend.downstreamUrl == "http://thanos-query.monitoring.svc:9090" &&
      yamldecode(helm_release.thanos[0].values[0]).storegateway.replicaCount == 2 &&
      yamldecode(helm_release.thanos[0].values[0]).storegateway.persistence.storageClass == "longhorn" &&
      yamldecode(helm_release.thanos[0].values[0]).storegateway.persistence.size == "3Gi" &&
      yamldecode(helm_release.thanos[0].values[0]).compactor.replicaCount == 1 &&
      yamldecode(helm_release.thanos[0].values[0]).compactor.persistence.storageClass == "hcloud-volumes-retain" &&
      yamldecode(helm_release.thanos[0].values[0]).compactor.persistence.size == "50Gi" &&
      yamldecode(helm_release.thanos[0].values[0]).compactor.retention.resolutionRaw == "30d" &&
      yamldecode(helm_release.thanos[0].values[0]).compactor.retention.resolution5m == "30d" &&
      yamldecode(helm_release.thanos[0].values[0]).compactor.retention.resolution1h == "30d"
    )
    error_message = "Thanos must upload to the configured object store, use Longhorn for its Store Gateway cache, and retain all resolutions for 30 days."
  }

  assert {
    condition = (
      contains(yamldecode(helm_release.kube_prometheus_stack[0].values[0])["kube-state-metrics"].metricLabelsAllowlist, "pods=[app,session-id]") &&
      contains(keys(yamldecode(helm_release.kube_prometheus_stack[0].values[0]).additionalPrometheusRulesMap), "vtafarm-pod-resources") &&
      contains(
        yamldecode(helm_release.kube_prometheus_stack[0].values[0]).additionalPrometheusRulesMap.vtafarm-pod-resources.groups[0].rules[*].record,
        "vtafarm:pod_cpu_usage_cores:rate1m",
      ) &&
      contains(
        yamldecode(helm_release.kube_prometheus_stack[0].values[0]).additionalPrometheusRulesMap.vtafarm-pod-resources.groups[0].rules[*].record,
        "vtafarm:pod_cpu_limit_cores",
      ) &&
      contains(
        yamldecode(helm_release.kube_prometheus_stack[0].values[0]).additionalPrometheusRulesMap.vtafarm-pod-resources.groups[0].rules[*].record,
        "vtafarm:pod_ready",
      ) &&
      contains(
        yamldecode(helm_release.kube_prometheus_stack[0].values[0]).additionalPrometheusRulesMap.vtafarm-pod-resources.groups[0].rules[*].record,
        "vtafarm:pod_container_restarts_total",
      ) &&
      contains(
        yamldecode(helm_release.kube_prometheus_stack[0].values[0]).additionalPrometheusRulesMap.vtafarm-pod-resources.groups[0].rules[*].record,
        "vtafarm:pod_network_receive_bytes_per_second:rate5m",
      ) &&
      contains(
        yamldecode(helm_release.kube_prometheus_stack[0].values[0]).additionalPrometheusRulesMap.vtafarm-pod-resources.groups[0].rules[*].record,
        "vtafarm:pod_network_transmit_bytes_per_second:rate5m",
      ) &&
      contains(
        yamldecode(helm_release.kube_prometheus_stack[0].values[0]).additionalPrometheusRulesMap.vtafarm-pod-resources.groups[0].rules[*].record,
        "vtafarm:pod_persistent_volume_used_bytes",
      ) &&
      contains(
        yamldecode(helm_release.kube_prometheus_stack[0].values[0]).additionalPrometheusRulesMap.vtafarm-pod-resources.groups[0].rules[*].record,
        "vtafarm:pod_persistent_volume_capacity_bytes",
      )
    )
    error_message = "Pod ownership labels and VTA Farm per-pod CPU, memory, network, and storage recording rules must be present."
  }

  assert {
    condition = alltrue([
      for rule in yamldecode(helm_release.kube_prometheus_stack[0].values[0]).additionalPrometheusRulesMap.vtafarm-pod-resources.groups[0].rules :
      strcontains(rule.expr, "max by (namespace, persistentvolumeclaim)")
      if rule.record == "vtafarm:pod_persistent_volume_used_bytes"
    ])
    error_message = "The PVC usage recording rule must deduplicate kubelet scrape replicas before joining volume metrics to pods."
  }

  assert {
    condition = alltrue([
      for rule in yamldecode(helm_release.kube_prometheus_stack[0].values[0]).additionalPrometheusRulesMap.vtafarm-pod-resources.groups[0].rules :
      strcontains(rule.expr, "max by (namespace, pod")
      if contains([
        "vtafarm:pod_cpu_usage_cores:rate1m",
        "vtafarm:pod_cpu_usage_cores:rate5m",
        "vtafarm:pod_memory_working_set_bytes",
        "vtafarm:pod_network_receive_bytes_per_second:rate5m",
        "vtafarm:pod_network_transmit_bytes_per_second:rate5m",
      ], rule.record)
    ])
    error_message = "cAdvisor recording rules must deduplicate samples exposed through multiple kubelet Services."
  }

  assert {
    condition = one([
      for rule in yamldecode(helm_release.kube_prometheus_stack[0].values[0]).additionalPrometheusRulesMap.vtafarm-pod-resources.groups[0].rules :
      strcontains(rule.expr, "kube_persistentvolumeclaim_resource_requests_storage_bytes")
      if rule.record == "vtafarm:pod_persistent_volume_capacity_bytes"
    ])
    error_message = "The PVC capacity recording rule must use the declared PVC capacity so limits remain available when kubelet volume stats are missing."
  }

  assert {
    condition = (
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).kubeControllerManager.enabled == false &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).kubeEtcd.enabled == false &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).kubeScheduler.enabled == false &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).kubeProxy.enabled == false
    )
    error_message = "Unsupported generic control-plane targets must stay disabled on RKE2."
  }
}

run "default_thanos_prefix_is_cluster_scoped" {
  command = plan

  variables {
    config = {
      cluster_name         = "rke2-vtafarm-staging"
      enabled              = true
      thanos_s3_bucket     = "vtafarm-thanos-test"
      thanos_s3_endpoint   = "nbg1.your-objectstorage.com"
      thanos_s3_region     = "nbg1"
      thanos_s3_access_key = "test-access-key"
      thanos_s3_secret_key = "test-secret-key"
    }
  }

  assert {
    condition     = output.thanos_s3_prefix == "thanos/rke2-vtafarm-staging"
    error_message = "An empty prefix must isolate Thanos blocks by cluster name."
  }
}

run "custom_prometheus_replicas_and_resources" {
  command = plan

  variables {
    config = {
      cluster_name              = "rke2-vtafarm-production"
      enabled                   = true
      thanos_enabled            = false
      prometheus_replicas       = 2
      prometheus_cpu_request    = "500m"
      prometheus_cpu_limit      = "1"
      prometheus_memory_request = "2Gi"
      prometheus_memory_limit   = "4Gi"
    }
  }

  assert {
    condition = (
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.replicas == 2 &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.resources.requests.cpu == "500m" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.resources.limits.cpu == "1" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.resources.requests.memory == "2Gi" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.resources.limits.memory == "4Gi" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.podAntiAffinity == "soft"
    )
    error_message = "Prometheus replica count and per-replica resources must follow configuration."
  }
}

run "prometheus_without_thanos" {
  command = plan

  variables {
    config = {
      cluster_name   = "rke2-vtafarm-development"
      enabled        = true
      thanos_enabled = false
    }
  }

  assert {
    condition = (
      length(helm_release.thanos) == 0 &&
      length(kubernetes_secret_v1.thanos_objstore) == 0 &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.thanosService.enabled == false &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.thanos == null &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).grafana.sidecar.datasources.url == "http://monitoring-prometheus.monitoring.svc:9090"
    )
    error_message = "Disabling Thanos must keep Prometheus standalone without an object-store secret."
  }
}

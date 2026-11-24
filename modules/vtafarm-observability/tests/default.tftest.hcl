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
      length(helm_release.loki) == 0 &&
      length(helm_release.alloy) == 0 &&
      length(kubernetes_namespace_v1.monitoring) == 0 &&
      length(kubernetes_namespace_v1.logging) == 0 &&
      length(kubernetes_secret_v1.thanos_objstore) == 0 &&
      length(kubernetes_secret_v1.loki_s3) == 0 &&
      length(kubernetes_storage_class_v1.hcloud_volumes_retain) == 0
    )
    error_message = "Observability must create no resources unless explicitly enabled."
  }
}

run "loki_and_alloy_logging_pipeline" {
  command = plan

  variables {
    config = {
      cluster_name          = "rke2-vtafarm-staging"
      enabled               = true
      thanos_enabled        = false
      loki_enabled          = true
      loki_replicas         = 3
      loki_gateway_replicas = 2
      loki_storage_size     = "20Gi"
      loki_s3_chunks_bucket = "loki"
      loki_s3_ruler_bucket  = "loki"
      loki_s3_chunks_prefix = "rke2-vtafarm-staging-loki-chunks"
      loki_s3_ruler_prefix  = "rke2-vtafarm-staging-loki-ruler"
      loki_s3_endpoint      = "nbg1.your-objectstorage.com"
      loki_s3_region        = "nbg1"
      loki_s3_access_key    = "test-access-key"
      loki_s3_secret_key    = "test-secret-key"
    }
  }

  assert {
    condition = (
      length(kubernetes_namespace_v1.logging) == 1 &&
      kubernetes_namespace_v1.logging[0].metadata[0].name == "logging" &&
      length(kubernetes_secret_v1.loki_s3) == 1 &&
      kubernetes_secret_v1.loki_s3[0].metadata[0].name == "loki-s3" &&
      kubernetes_secret_v1.loki_s3[0].metadata[0].namespace == "logging" &&
      kubernetes_secret_v1.loki_s3[0].data.AWS_ACCESS_KEY_ID == "test-access-key" &&
      kubernetes_secret_v1.loki_s3[0].data.AWS_SECRET_ACCESS_KEY == "test-secret-key"
    )
    error_message = "Loki S3 credentials must be injected through a dedicated Kubernetes Secret."
  }

  assert {
    condition = (
      helm_release.loki[0].name == "loki" &&
      helm_release.loki[0].namespace == "logging" &&
      helm_release.loki[0].version == "21.4.0" &&
      yamldecode(helm_release.loki[0].values[0]).deploymentMode == "Monolithic" &&
      yamldecode(helm_release.loki[0].values[0]).global.clusterDomain == "cluster.local" &&
      yamldecode(helm_release.loki[0].values[0]).global.dnsService == "rke2-coredns-rke2-coredns" &&
      yamldecode(helm_release.loki[0].values[0]).global.dnsNamespace == "kube-system" &&
      yamldecode(helm_release.loki[0].values[0]).memberlist.service.publishNotReadyAddresses == true &&
      yamldecode(helm_release.loki[0].values[0]).loki.auth_enabled == false &&
      yamldecode(helm_release.loki[0].values[0]).loki.commonConfig.replication_factor == 3 &&
      yamldecode(helm_release.loki[0].values[0]).loki.schemaConfig.configs[0].store == "tsdb" &&
      yamldecode(helm_release.loki[0].values[0]).loki.schemaConfig.configs[0].schema == "v13" &&
      yamldecode(helm_release.loki[0].values[0]).loki.schemaConfig.configs[0].index.period == "24h" &&
      yamldecode(helm_release.loki[0].values[0]).loki.storage.bucketNames.chunks == "loki" &&
      yamldecode(helm_release.loki[0].values[0]).loki.storage.bucketNames.ruler == "loki" &&
      yamldecode(helm_release.loki[0].values[0]).loki.storage.use_thanos_objstore == true &&
      yamldecode(helm_release.loki[0].values[0]).loki.storage.object_store.storage_prefix == "rke2-vtafarm-staging-loki-chunks" &&
      yamldecode(helm_release.loki[0].values[0]).loki.storage.object_store.s3.access_key_id == "$${AWS_ACCESS_KEY_ID}" &&
      yamldecode(helm_release.loki[0].values[0]).loki.storage.object_store.s3.secret_access_key == "$${AWS_SECRET_ACCESS_KEY}" &&
      yamldecode(helm_release.loki[0].values[0]).loki.structuredConfig.ruler_storage.storage_prefix == "rke2-vtafarm-staging-loki-ruler" &&
      !strcontains(helm_release.loki[0].values[0], "test-secret-key") &&
      yamldecode(helm_release.loki[0].values[0]).loki.limits_config.retention_period == "720h" &&
      yamldecode(helm_release.loki[0].values[0]).loki.compactor.retention_enabled == true &&
      yamldecode(helm_release.loki[0].values[0]).loki.compactor.delete_request_store == "s3"
    )
    error_message = "Loki must use RKE2 DNS, bootstrap memberlist, and configure monolithic TSDB v13 with cluster-scoped S3 storage and retention."
  }

  assert {
    condition = (
      yamldecode(helm_release.loki[0].values[0]).singleBinary.replicas == 3 &&
      yamldecode(helm_release.loki[0].values[0]).singleBinary.persistence.storageClass == "hcloud-volumes-retain" &&
      yamldecode(helm_release.loki[0].values[0]).singleBinary.persistence.size == "20Gi" &&
      yamldecode(helm_release.loki[0].values[0]).singleBinary.persistence.enableStatefulSetAutoDeletePVC == false &&
      yamldecode(helm_release.loki[0].values[0]).singleBinary.podDisruptionBudget.minAvailable == 2 &&
      !contains(keys(yamldecode(helm_release.loki[0].values[0]).singleBinary.affinity), "nodeAffinity") &&
      contains(keys(yamldecode(helm_release.loki[0].values[0]).singleBinary.affinity), "podAntiAffinity") &&
      yamldecode(helm_release.loki[0].values[0]).gateway.replicas == 2 &&
      yamldecode(helm_release.loki[0].values[0]).gateway.podDisruptionBudget.minAvailable == 1 &&
      yamldecode(helm_release.loki[0].values[0]).chunksCache.enabled == false &&
      yamldecode(helm_release.loki[0].values[0]).resultsCache.enabled == false &&
      yamldecode(helm_release.loki[0].values[0]).monitoring.serviceMonitor.enabled == true
    )
    error_message = "Staging Loki must use the approved three-replica, 20Gi, two-gateway topology without oversized caches."
  }

  assert {
    condition = (
      helm_release.alloy[0].name == "alloy" &&
      helm_release.alloy[0].namespace == "logging" &&
      helm_release.alloy[0].version == "1.16.0" &&
      yamldecode(helm_release.alloy[0].values[0]).controller.type == "daemonset" &&
      yamldecode(helm_release.alloy[0].values[0]).alloy.clustering.enabled == false &&
      yamldecode(helm_release.alloy[0].values[0]).alloy.storagePath == "/var/lib/alloy" &&
      yamldecode(helm_release.alloy[0].values[0]).alloy.mounts.varlog == true &&
      yamldecode(helm_release.alloy[0].values[0]).controller.volumes.extra[0].hostPath.path == "/var/lib/alloy" &&
      yamldecode(helm_release.alloy[0].values[0]).serviceMonitor.enabled == true &&
      strcontains(yamldecode(helm_release.alloy[0].values[0]).alloy.configMap.content, "spec.nodeName=") &&
      strcontains(yamldecode(helm_release.alloy[0].values[0]).alloy.configMap.content, "/var/log/pods/*$1/*.log") &&
      strcontains(yamldecode(helm_release.alloy[0].values[0]).alloy.configMap.content, "stage.structured_metadata") &&
      strcontains(yamldecode(helm_release.alloy[0].values[0]).alloy.configMap.content, "http://loki-gateway.logging.svc/loki/api/v1/push")
    )
    error_message = "Alloy must run once per node, persist file positions, collect only local CRI Pod logs, and write through the private Loki gateway."
  }

  assert {
    condition = (
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).grafana.additionalDataSources[0].name == "Loki" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).grafana.additionalDataSources[0].url == "http://loki-gateway.logging.svc" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).grafana.sidecar.dashboards.searchNamespace == "ALL" &&
      length(keys(yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.serviceMonitorNamespaceSelector)) == 0 &&
      length(keys(yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.ruleNamespaceSelector)) == 0
    )
    error_message = "Grafana and Prometheus must discover logging data, dashboards, monitors, and rules across namespaces."
  }
}

run "single_replica_loki_can_run_on_control_plane" {
  command = plan

  variables {
    config = {
      cluster_name          = "rke2-vtafarm-dev"
      enabled               = true
      thanos_enabled        = false
      loki_enabled          = true
      loki_replicas         = 1
      loki_s3_chunks_bucket = "loki"
      loki_s3_ruler_bucket  = "loki"
      loki_s3_endpoint      = "nbg1.your-objectstorage.com"
      loki_s3_region        = "nbg1"
      loki_s3_access_key    = "test-access-key"
      loki_s3_secret_key    = "test-secret-key"
    }
  }

  assert {
    condition = (
      yamldecode(helm_release.loki[0].values[0]).singleBinary.replicas == 1 &&
      !contains(keys(yamldecode(helm_release.loki[0].values[0]).singleBinary.affinity), "nodeAffinity") &&
      contains(keys(yamldecode(helm_release.loki[0].values[0]).singleBinary.affinity), "podAntiAffinity")
    )
    error_message = "Single-replica dev Loki must remain spread-aware without excluding the only control-plane worker."
  }
}

run "prometheus_on_retained_hcloud_volume" {
  command = plan

  variables {
    config = {
      cluster_name                   = "rke2-vtafarm-production"
      enabled                        = true
      thanos_s3_bucket               = "vtafarm-thanos-test"
      thanos_s3_prefix               = "observability/production/metrics"
      thanos_s3_endpoint             = "nbg1.your-objectstorage.com"
      thanos_s3_region               = "nbg1"
      thanos_s3_access_key           = "test-access-key"
      thanos_s3_secret_key           = "test-secret-key"
      thanos_query_replicas          = 1
      thanos_query_frontend_replicas = 3
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
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.retentionSize == "16GB" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.replicas == 1 &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.externalLabels.cluster == "rke2-vtafarm-production" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.thanos.objectStorageConfig.existingSecret.name == "thanos-objstore" &&
      !contains(keys(yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.thanos), "image") &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues == false &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.thanosService.enabled == true &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).grafana.sidecar.datasources.url == "http://thanos-query-frontend.monitoring.svc:9090" &&
      !contains(keys(yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.resources.limits), "cpu") &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName == "hcloud-volumes-retain" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage == "20Gi"
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
      yamldecode(helm_release.thanos[0].values[0]).query.replicaCount == 1 &&
      yamldecode(helm_release.thanos[0].values[0]).queryFrontend.enabled == true &&
      yamldecode(helm_release.thanos[0].values[0]).queryFrontend.replicaCount == 3 &&
      yamldecode(helm_release.thanos[0].values[0]).queryFrontend.pdb.enabled == true &&
      yamldecode(helm_release.thanos[0].values[0]).queryFrontend.downstreamUrl == "http://thanos-query.monitoring.svc:9090" &&
      yamldecode(helm_release.thanos[0].values[0]).storegateway.replicaCount == 2 &&
      yamldecode(helm_release.thanos[0].values[0]).storegateway.persistence.storageClass == "longhorn" &&
      yamldecode(helm_release.thanos[0].values[0]).storegateway.persistence.size == "3Gi" &&
      yamldecode(helm_release.thanos[0].values[0]).compactor.replicaCount == 1 &&
      yamldecode(helm_release.thanos[0].values[0]).compactor.persistence.storageClass == "hcloud-volumes" &&
      yamldecode(helm_release.thanos[0].values[0]).compactor.persistence.size == "50Gi" &&
      yamldecode(helm_release.thanos[0].values[0]).compactor.retention.resolutionRaw == "30d" &&
      yamldecode(helm_release.thanos[0].values[0]).compactor.retention.resolution5m == "30d" &&
      yamldecode(helm_release.thanos[0].values[0]).compactor.retention.resolution1h == "30d"
    )
    error_message = "Thanos component replica counts, object storage, cache storage, and retention must follow configuration."
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

run "alertmanager_high_availability" {
  command = plan

  variables {
    config = {
      cluster_name          = "rke2-vtafarm-production"
      enabled               = true
      thanos_enabled        = false
      alertmanager_enabled  = true
      alertmanager_replicas = 2
    }
  }

  assert {
    condition = (
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).alertmanager.enabled == true &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).alertmanager.alertmanagerSpec.replicas == 2 &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).alertmanager.alertmanagerSpec.podAntiAffinity == "soft" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).alertmanager.alertmanagerSpec.podAntiAffinityTopologyKey == "kubernetes.io/hostname"
    )
    error_message = "Alertmanager enablement, replica count, and node spreading must follow configuration."
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

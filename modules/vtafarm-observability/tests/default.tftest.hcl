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
      length(kubernetes_namespace_v1.monitoring) == 0 &&
      length(kubernetes_storage_class_v1.hcloud_volumes_retain) == 0
    )
    error_message = "Observability must create no resources unless explicitly enabled."
  }
}

run "prometheus_on_retained_hcloud_volume" {
  command = plan

  variables {
    config = {
      cluster_name = "rke2-vtafarm-production"
      enabled      = true
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
      helm_release.kube_prometheus_stack[0].version == "93.2.2" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).alertmanager.enabled == false &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).grafana.enabled == true &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.retention == "15d" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.retentionSize == "40GB" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.replicas == 1 &&
      !contains(keys(yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.resources.limits), "cpu") &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName == "hcloud-volumes-retain" &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage == "50Gi"
    )
    error_message = "Prometheus must keep bounded history on the configured Hetzner Volume."
  }

  assert {
    condition = (
      contains(yamldecode(helm_release.kube_prometheus_stack[0].values[0])["kube-state-metrics"].metricLabelsAllowlist, "pods=[app,session-id]") &&
      contains(keys(yamldecode(helm_release.kube_prometheus_stack[0].values[0]).additionalPrometheusRulesMap), "vtafarm-pod-resources") &&
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
    condition = (
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).kubeControllerManager.enabled == false &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).kubeEtcd.enabled == false &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).kubeScheduler.enabled == false &&
      yamldecode(helm_release.kube_prometheus_stack[0].values[0]).kubeProxy.enabled == false
    )
    error_message = "Unsupported generic control-plane targets must stay disabled on RKE2."
  }
}

run "custom_prometheus_replicas_and_resources" {
  command = plan

  variables {
    config = {
      cluster_name              = "rke2-vtafarm-production"
      enabled                   = true
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

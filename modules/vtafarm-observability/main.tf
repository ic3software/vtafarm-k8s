locals {
  release_name = "vtafarm-monitoring"

  # The RKE2 control-plane processes are static pods whose metrics listeners
  # are not exposed through the Services this chart assumes. Keep their
  # monitors and matching rules off until an authenticated RKE2-specific
  # scrape path is deliberately configured; kubelet, cAdvisor, API server,
  # CoreDNS, node-exporter and kube-state-metrics remain enabled.
  chart_values = {
    fullnameOverride = local.release_name
    commonLabels = {
      "app.kubernetes.io/managed-by" = "opentofu"
      "vtafarm.ic3.dev/cluster"      = var.config.cluster_name
    }

    crds = {
      enabled = true
      upgradeJob = {
        enabled = false
      }
    }

    defaultRules = {
      create = true
      rules = {
        etcd                   = false
        kubeControllerManager  = false
        kubeProxy              = false
        kubeSchedulerAlerting  = false
        kubeSchedulerRecording = false
        windows                = false
      }
    }

    kubeControllerManager = { enabled = false }
    kubeEtcd              = { enabled = false }
    kubeScheduler         = { enabled = false }
    kubeProxy             = { enabled = false }
    windowsMonitoring     = { enabled = false }

    kubeStateMetrics = { enabled = true }
    "kube-state-metrics" = {
      metricLabelsAllowlist = [
        "namespaces=[managed-by,user-id]",
        "pods=[app,session-id]",
        "persistentvolumeclaims=[managed-by,session-id,component]",
      ]
      resources = {
        requests = { cpu = "25m", memory = "64Mi" }
        limits   = { memory = "256Mi" }
      }
    }

    nodeExporter = { enabled = true }
    "prometheus-node-exporter" = {
      resources = {
        requests = { cpu = "20m", memory = "32Mi" }
        limits   = { memory = "128Mi" }
      }
    }

    prometheusOperator = {
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "256Mi" }
      }
    }

    prometheus = {
      enabled = true
      ingress = { enabled = false }
      service = {
        enabled = true
        type    = "ClusterIP"
      }
      prometheusSpec = {
        replicas           = 1
        scrapeInterval     = var.config.scrape_interval
        evaluationInterval = var.config.evaluation_interval
        retention          = var.config.prometheus_retention
        retentionSize      = var.config.prometheus_retention_size
        walCompression     = true
        enableAdminAPI     = false

        persistentVolumeClaimRetentionPolicy = {
          whenDeleted = "Retain"
          whenScaled  = "Retain"
        }
        storageSpec = {
          volumeClaimTemplate = {
            spec = {
              storageClassName = var.config.storage_class_name
              accessModes      = ["ReadWriteOnce"]
              resources = {
                requests = { storage = var.config.prometheus_storage_size }
              }
            }
          }
        }
        resources = {
          requests = {
            cpu    = var.config.prometheus_cpu_request
            memory = var.config.prometheus_memory_request
          }
          limits = {
            memory = var.config.prometheus_memory_limit
          }
        }

        # The API and tenant charts may add their own ServiceMonitor or
        # PodMonitor later. Empty selectors with the Helm-value fallback off
        # let this one Prometheus discover them across namespaces.
        serviceMonitorSelectorNilUsesHelmValues = false
        serviceMonitorSelector                  = {}
        serviceMonitorNamespaceSelector         = {}
        podMonitorSelectorNilUsesHelmValues     = false
        podMonitorSelector                      = {}
        podMonitorNamespaceSelector             = {}
      }
    }

    alertmanager = {
      enabled = var.config.alertmanager_enabled
      ingress = { enabled = false }
      alertmanagerSpec = {
        replicas  = 1
        retention = "120h"
        resources = {
          requests = { cpu = "25m", memory = "64Mi" }
          limits   = { memory = "256Mi" }
        }
      }
    }

    grafana = {
      enabled                   = var.config.grafana_enabled
      defaultDashboardsEnabled  = true
      defaultDashboardsTimezone = "utc"
      ingress                   = { enabled = false }
      persistence               = { enabled = false }
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "512Mi" }
      }
    }

    # Stable, tenant-safe aggregates. The application API will still verify
    # database ownership before querying by label_session_id; Prometheus and
    # Grafana stay private ClusterIP services.
    additionalPrometheusRulesMap = {
      "vtafarm-pod-resources" = {
        groups = [{
          name     = "vtafarm.pod-resources"
          interval = var.config.evaluation_interval
          rules = [
            {
              record = "vtafarm:pod_cpu_usage_cores:rate5m"
              expr   = <<-PROMQL
                sum by (namespace, pod, label_session_id, label_app) (
                  rate(container_cpu_usage_seconds_total{container!="",container!="POD",image!=""}[5m])
                  * on (namespace, pod) group_left(label_session_id, label_app)
                  kube_pod_labels{label_session_id!=""}
                )
              PROMQL
            },
            {
              record = "vtafarm:pod_memory_working_set_bytes"
              expr   = <<-PROMQL
                sum by (namespace, pod, label_session_id, label_app) (
                  container_memory_working_set_bytes{container!="",container!="POD",image!=""}
                  * on (namespace, pod) group_left(label_session_id, label_app)
                  kube_pod_labels{label_session_id!=""}
                )
              PROMQL
            },
            {
              record = "vtafarm:pod_cpu_requested_cores"
              expr   = <<-PROMQL
                sum by (namespace, pod, label_session_id, label_app) (
                  kube_pod_container_resource_requests{resource="cpu",unit="core"}
                  * on (namespace, pod) group_left(label_session_id, label_app)
                  kube_pod_labels{label_session_id!=""}
                )
              PROMQL
            },
            {
              record = "vtafarm:pod_memory_requested_bytes"
              expr   = <<-PROMQL
                sum by (namespace, pod, label_session_id, label_app) (
                  kube_pod_container_resource_requests{resource="memory",unit="byte"}
                  * on (namespace, pod) group_left(label_session_id, label_app)
                  kube_pod_labels{label_session_id!=""}
                )
              PROMQL
            },
            {
              record = "vtafarm:pod_memory_limit_bytes"
              expr   = <<-PROMQL
                sum by (namespace, pod, label_session_id, label_app) (
                  kube_pod_container_resource_limits{resource="memory",unit="byte"}
                  * on (namespace, pod) group_left(label_session_id, label_app)
                  kube_pod_labels{label_session_id!=""}
                )
              PROMQL
            },
            {
              record = "vtafarm:pod_network_receive_bytes_per_second:rate5m"
              expr   = <<-PROMQL
                sum by (namespace, pod, label_session_id, label_app) (
                  sum by (namespace, pod) (
                    rate(container_network_receive_bytes_total{pod!="",interface!="lo"}[5m])
                  )
                  * on (namespace, pod) group_left(label_session_id, label_app)
                  kube_pod_labels{label_session_id!=""}
                )
              PROMQL
            },
            {
              record = "vtafarm:pod_network_transmit_bytes_per_second:rate5m"
              expr   = <<-PROMQL
                sum by (namespace, pod, label_session_id, label_app) (
                  sum by (namespace, pod) (
                    rate(container_network_transmit_bytes_total{pod!="",interface!="lo"}[5m])
                  )
                  * on (namespace, pod) group_left(label_session_id, label_app)
                  kube_pod_labels{label_session_id!=""}
                )
              PROMQL
            },
            {
              record = "vtafarm:pod_persistent_volume_used_bytes"
              expr   = <<-PROMQL
                max by (namespace, pod, persistentvolumeclaim, label_session_id, label_app) (
                  kubelet_volume_stats_used_bytes
                  * on (namespace, persistentvolumeclaim) group_right
                  max by (namespace, pod, persistentvolumeclaim) (
                    kube_pod_spec_volumes_persistentvolumeclaims_info
                  )
                  * on (namespace, pod) group_left(label_session_id, label_app)
                  kube_pod_labels{label_session_id!=""}
                )
              PROMQL
            },
            {
              record = "vtafarm:pod_persistent_volume_capacity_bytes"
              expr   = <<-PROMQL
                max by (namespace, pod, persistentvolumeclaim, label_session_id, label_app) (
                  kubelet_volume_stats_capacity_bytes
                  * on (namespace, persistentvolumeclaim) group_right
                  max by (namespace, pod, persistentvolumeclaim) (
                    kube_pod_spec_volumes_persistentvolumeclaims_info
                  )
                  * on (namespace, pod) group_left(label_session_id, label_app)
                  kube_pod_labels{label_session_id!=""}
                )
              PROMQL
            },
          ]
        }]
      }
    }
  }
}

resource "kubernetes_namespace_v1" "monitoring" {
  count = var.config.enabled ? 1 : 0

  metadata {
    name = var.config.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "opentofu"
      "vtafarm.ic3.dev/purpose"      = "observability"
    }
  }
}

# hcloud-csi's built-in class deletes its cloud Volume with the PVC. Metrics
# are replaceable, but an accidental Helm uninstall should not silently erase
# their history. A retained PV can be re-bound or deliberately purged later.
resource "kubernetes_storage_class_v1" "hcloud_volumes_retain" {
  count = var.config.enabled ? 1 : 0

  metadata {
    name = var.config.storage_class_name
  }

  storage_provisioner    = "csi.hetzner.cloud"
  reclaim_policy         = "Retain"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"
}

resource "helm_release" "kube_prometheus_stack" {
  count = var.config.enabled ? 1 : 0

  name      = local.release_name
  chart     = "oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack"
  version   = var.config.chart_version
  namespace = kubernetes_namespace_v1.monitoring[0].metadata[0].name

  values = [yamlencode(local.chart_values)]

  wait    = true
  timeout = 900

  depends_on = [kubernetes_storage_class_v1.hcloud_volumes_retain]
}

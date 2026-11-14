locals {
  release_name                = "monitoring"
  thanos_release_name         = "thanos"
  thanos_objstore_secret_name = "thanos-objstore"
  prometheus_url              = "http://${local.release_name}-prometheus.${var.config.namespace}.svc:9090"
  thanos_query_url            = "http://${local.thanos_release_name}-query.${var.config.namespace}.svc:9090"
  thanos_s3_prefix            = var.config.thanos_s3_prefix != "" ? var.config.thanos_s3_prefix : "thanos/${var.config.cluster_name}"

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
      thanosService = {
        enabled = var.config.thanos_enabled
        type    = "ClusterIP"
      }
      thanosServiceMonitor = {
        enabled  = var.config.thanos_enabled
        interval = var.config.scrape_interval
      }
      service = {
        enabled = true
        type    = "ClusterIP"
      }
      prometheusSpec = {
        replicas           = var.config.prometheus_replicas
        scrapeInterval     = var.config.scrape_interval
        evaluationInterval = var.config.evaluation_interval
        retention          = var.config.prometheus_retention
        retentionSize      = var.config.prometheus_retention_size
        walCompression     = true
        enableAdminAPI     = false
        externalLabels = var.config.thanos_enabled ? {
          cluster = var.config.cluster_name
        } : {}
        thanos = var.config.thanos_enabled ? {
          image = "quay.io/thanos/thanos:${var.config.thanos_image_version}"
          objectStorageConfig = {
            existingSecret = {
              name = local.thanos_objstore_secret_name
              key  = "objstore.yml"
            }
          }
        } : null

        # Prefer separate nodes when replicas are requested, but keep a
        # single-node development cluster schedulable.
        podAntiAffinity            = "soft"
        podAntiAffinityTopologyKey = "kubernetes.io/hostname"

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
          limits = merge(
            { memory = var.config.prometheus_memory_limit },
            var.config.prometheus_cpu_limit == null ? {} : { cpu = var.config.prometheus_cpu_limit },
          )
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
        ruleSelectorNilUsesHelmValues           = false
        ruleSelector                            = {}
        ruleNamespaceSelector                   = {}
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
      sidecar = {
        datasources = {
          url = var.config.thanos_enabled ? local.thanos_query_url : local.prometheus_url
        }
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

  thanos_values = {
    fullnameOverride = local.thanos_release_name

    global = {
      image = {
        registry   = "quay.io"
        repository = "thanos/thanos"
        tag        = var.config.thanos_image_version
      }
      commonLabels = {
        "app.kubernetes.io/managed-by" = "opentofu"
        "vtafarm.ic3.dev/cluster"      = var.config.cluster_name
      }
      storageClass    = var.config.storage_class_name
      networkPolicies = false
      objstore = {
        createSecret = false
        secretName   = local.thanos_objstore_secret_name
        secretKey    = "objstore.yml"
      }
      serviceMonitor = {
        enabled  = true
        interval = var.config.scrape_interval
      }
    }

    bucket = {
      enabled = true
      bucketweb = {
        enabled = false
      }
    }

    compactor = {
      enabled      = true
      replicaCount = 1
      persistence = {
        enabled = true
        size    = var.config.thanos_compactor_storage_size
      }
      vpa = {
        enabled = false
      }
      retention = {
        resolutionRaw = var.config.thanos_retention
        resolution5m  = var.config.thanos_retention
        resolution1h  = var.config.thanos_retention
      }
      resources = {
        requests = { cpu = "500m", memory = "1Gi" }
        limits   = { memory = "4Gi" }
      }
    }

    query = {
      enabled      = true
      replicaCount = var.config.thanos_query_replicas
      service = {
        type = "ClusterIP"
      }
      ingress = {
        enabled = false
        http    = { enabled = false }
        grpc    = { enabled = false }
      }
      endpoints = {
        autogen = { enabled = true }
        static = [
          "dnssrv+_grpc._tcp.${local.release_name}-thanos-discovery.${var.config.namespace}.svc.cluster.local",
        ]
      }
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "1Gi" }
      }
      pdb = {
        enabled      = var.config.thanos_query_replicas > 1
        minAvailable = var.config.thanos_query_replicas > 1 ? 1 : ""
      }
    }

    queryFrontend = {
      enabled = false
    }

    storegateway = {
      enabled      = true
      replicaCount = var.config.thanos_storegateway_replicas
      service = {
        type = "ClusterIP"
      }
      ingress = {
        enabled = false
        http    = { enabled = false }
        grpc    = { enabled = false }
      }
      persistence = {
        enabled = true
        size    = var.config.thanos_storegateway_storage_size
      }
      resources = {
        requests = { cpu = "100m", memory = "512Mi" }
        limits   = { memory = "2Gi" }
      }
      pdb = {
        enabled      = var.config.thanos_storegateway_replicas > 1
        minAvailable = var.config.thanos_storegateway_replicas > 1 ? 1 : ""
      }
    }

    receive = { enabled = false }
    ruler   = { enabled = false }
    rustfs  = { enabled = false }

    "kube-prometheus-stack" = {
      enabled = false
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

resource "kubernetes_secret_v1" "thanos_objstore" {
  count = var.config.enabled && var.config.thanos_enabled ? 1 : 0

  metadata {
    name      = local.thanos_objstore_secret_name
    namespace = kubernetes_namespace_v1.monitoring[0].metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "opentofu"
      "vtafarm.ic3.dev/cluster"      = var.config.cluster_name
    }
  }

  type = "Opaque"
  data = {
    "objstore.yml" = yamlencode({
      type   = "S3"
      prefix = local.thanos_s3_prefix
      config = {
        bucket             = var.config.thanos_s3_bucket
        endpoint           = var.config.thanos_s3_endpoint
        region             = var.config.thanos_s3_region
        access_key         = var.config.thanos_s3_access_key
        secret_key         = var.config.thanos_s3_secret_key
        insecure           = false
        signature_version2 = false
      }
    })
  }
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

  depends_on = [
    kubernetes_secret_v1.thanos_objstore,
    kubernetes_storage_class_v1.hcloud_volumes_retain,
  ]
}

resource "helm_release" "thanos" {
  count = var.config.enabled && var.config.thanos_enabled ? 1 : 0

  name      = local.thanos_release_name
  chart     = "oci://ghcr.io/thanos-community/helm-charts/thanos"
  version   = var.config.thanos_chart_version
  namespace = kubernetes_namespace_v1.monitoring[0].metadata[0].name

  values = [yamlencode(local.thanos_values)]

  wait    = true
  timeout = 900

  depends_on = [
    helm_release.kube_prometheus_stack,
    kubernetes_secret_v1.thanos_objstore,
  ]
}

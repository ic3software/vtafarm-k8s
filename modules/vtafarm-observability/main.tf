locals {
  release_name                = "monitoring"
  thanos_release_name         = "thanos"
  thanos_objstore_secret_name = "thanos-objstore"
  loki_release_name           = "loki"
  alloy_release_name          = "alloy"
  loki_s3_secret_name         = "loki-s3"
  prometheus_url              = "http://${local.release_name}-prometheus.${var.config.monitoring_namespace}.svc:9090"
  thanos_query_url            = "http://${local.thanos_release_name}-query.${var.config.monitoring_namespace}.svc:9090"
  thanos_query_frontend_url   = "http://${local.thanos_release_name}-query-frontend.${var.config.monitoring_namespace}.svc:9090"
  loki_gateway_url            = "http://${local.loki_release_name}-gateway.${var.config.logging_namespace}.svc"
  thanos_s3_prefix            = var.config.thanos_s3_prefix != "" ? var.config.thanos_s3_prefix : "thanos/${var.config.cluster_name}"
  tenant_alert_warning_text = lookup({
    "1m"  = "1 minute"
    "10m" = "10 minutes"
  }, var.config.tenant_alert_warning_for, var.config.tenant_alert_warning_for)
  tenant_alert_critical_text = lookup({
    "1m" = "1 minute"
    "5m" = "5 minutes"
  }, var.config.tenant_alert_critical_for, var.config.tenant_alert_critical_for)

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

    # Scrape the same kubelet node-resource metrics used by metrics-server so
    # the admin dashboard can compare Prometheus and Kubernetes without
    # mixing whole-node usage with a container-only sum.
    kubelet = {
      serviceMonitor = {
        resource         = true
        resourcePath     = "/metrics/resource"
        resourceInterval = var.config.scrape_interval
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
        externalLabels = {
          cluster = var.config.cluster_name
        }
        thanos = var.config.thanos_enabled ? {
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

    alertmanager = merge({
      enabled = var.config.alertmanager_enabled
      ingress = { enabled = false }
      alertmanagerSpec = merge({
        replicas                   = var.config.alertmanager_replicas
        retention                  = "120h"
        podAntiAffinity            = "soft"
        podAntiAffinityTopologyKey = "kubernetes.io/hostname"
        resources = {
          requests = { cpu = "25m", memory = "64Mi" }
          limits   = { memory = "256Mi" }
        }
        podMetadata = {
          annotations = var.config.alertmanager_webhook_enabled ? {
            "vtafarm.ic3.dev/alertmanager-webhook-token-revision" = tostring(var.config.alertmanager_webhook_token_revision)
          } : {}
        }
        }, var.config.alertmanager_webhook_enabled ? {
        secrets = [var.config.alertmanager_webhook_secret_name]
      } : {})
      }, var.config.alertmanager_webhook_enabled ? {
      config = {
        global = { resolve_timeout = "5m" }
        route = {
          receiver        = "null"
          group_by        = ["namespace"]
          group_wait      = "30s"
          group_interval  = "5m"
          repeat_interval = "12h"
          routes = [{
            receiver        = "vtafarm-api"
            matchers        = ["audience=\"tenant\""]
            group_by        = ["cluster", "label_session_id", "label_app", "alertname", "resource"]
            group_wait      = var.config.alertmanager_tenant_group_wait
            group_interval  = var.config.alertmanager_tenant_group_interval
            repeat_interval = "12h"
          }]
        }
        inhibit_rules = [{
          source_matchers = ["audience=\"tenant\"", "severity=\"critical\""]
          target_matchers = ["audience=\"tenant\"", "severity=\"warning\""]
          equal           = ["cluster", "label_session_id", "label_app", "resource"]
        }]
        receivers = [
          { name = "null" },
          {
            name = "vtafarm-api"
            webhook_configs = [{
              url           = var.config.alertmanager_webhook_url
              send_resolved = true
              http_config = {
                authorization = {
                  type             = "Bearer"
                  credentials_file = "/etc/alertmanager/secrets/${var.config.alertmanager_webhook_secret_name}/ALERTMANAGER_WEBHOOK_TOKEN"
                }
              }
            }]
          },
        ]
      }
    } : {})

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
        dashboards = {
          searchNamespace = "ALL"
        }
        datasources = {
          url = var.config.thanos_enabled ? local.thanos_query_frontend_url : local.prometheus_url
        }
      }
      additionalDataSources = var.config.loki_enabled ? [{
        name      = "Loki"
        type      = "loki"
        access    = "proxy"
        url       = local.loki_gateway_url
        isDefault = false
        jsonData = {
          maxLines = 1000
        }
      }] : []
    }

    # Stable, tenant-safe aggregates. The application API will still verify
    # database ownership before querying by label_session_id; Prometheus and
    # Grafana stay private ClusterIP services. The inner max aggregations on
    # cAdvisor metrics deduplicate identical samples exposed through multiple
    # kubelet Services during a Helm fullname migration.
    additionalPrometheusRulesMap = {
      "vtafarm-pod-resources" = {
        groups = [{
          name     = "vtafarm.pod-resources"
          interval = var.config.evaluation_interval
          rules = [
            {
              record = "vtafarm:pod_cpu_usage_cores:rate1m"
              expr   = <<-PROMQL
                sum by (namespace, pod, label_session_id, label_app) (
                  max by (namespace, pod, container) (
                    rate(container_cpu_usage_seconds_total{container!="",container!="POD",image!=""}[1m])
                  )
                  * on (namespace, pod) group_left(label_session_id, label_app)
                  kube_pod_labels{label_session_id!=""}
                )
              PROMQL
            },
            {
              record = "vtafarm:pod_cpu_usage_cores:rate5m"
              expr   = <<-PROMQL
                sum by (namespace, pod, label_session_id, label_app) (
                  max by (namespace, pod, container) (
                    rate(container_cpu_usage_seconds_total{container!="",container!="POD",image!=""}[5m])
                  )
                  * on (namespace, pod) group_left(label_session_id, label_app)
                  kube_pod_labels{label_session_id!=""}
                )
              PROMQL
            },
            {
              record = "vtafarm:pod_memory_working_set_bytes"
              expr   = <<-PROMQL
                sum by (namespace, pod, label_session_id, label_app) (
                  max by (namespace, pod, container) (
                    container_memory_working_set_bytes{container!="",container!="POD",image!=""}
                  )
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
              record = "vtafarm:pod_cpu_limit_cores"
              expr   = <<-PROMQL
                sum by (namespace, pod, label_session_id, label_app) (
                  kube_pod_container_resource_limits{resource="cpu",unit="core"}
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
              record = "vtafarm:pod_ready"
              expr   = <<-PROMQL
                max by (namespace, pod, label_session_id, label_app) (
                  kube_pod_status_ready{condition="true"}
                  * on (namespace, pod) group_left(label_session_id, label_app)
                  kube_pod_labels{label_session_id!=""}
                )
              PROMQL
            },
            {
              record = "vtafarm:pod_container_restarts_total"
              expr   = <<-PROMQL
                sum by (namespace, pod, label_session_id, label_app) (
                  kube_pod_container_status_restarts_total
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
                    max by (namespace, pod, interface) (
                      rate(container_network_receive_bytes_total{pod!="",interface!="lo"}[5m])
                    )
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
                    max by (namespace, pod, interface) (
                      rate(container_network_transmit_bytes_total{pod!="",interface!="lo"}[5m])
                    )
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
                  max by (namespace, persistentvolumeclaim) (
                    kubelet_volume_stats_used_bytes
                  )
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
                  max by (namespace, persistentvolumeclaim) (
                    kube_persistentvolumeclaim_resource_requests_storage_bytes
                  )
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
      "vtafarm-tenant-alerts" = {
        groups = [{
          name     = "vtafarm.tenant-alerts"
          interval = var.config.evaluation_interval
          rules = [
            {
              alert  = "VTAFarmCPUUsageHigh"
              expr   = <<-PROMQL
                (
                  100 * max by (namespace, label_session_id, label_app) (
                    vtafarm:pod_cpu_usage_cores:rate${var.config.tenant_cpu_usage_window}
                    / clamp_min(vtafarm:pod_cpu_limit_cores, 0.001)
                  ) >= 75
                ) and (
                  100 * max by (namespace, label_session_id, label_app) (
                    vtafarm:pod_cpu_usage_cores:rate${var.config.tenant_cpu_usage_window}
                    / clamp_min(vtafarm:pod_cpu_limit_cores, 0.001)
                  ) < 90
                )
              PROMQL
              for    = var.config.tenant_alert_warning_for
              labels = { audience = "tenant", category = "resource", resource = "cpu", severity = "warning" }
              annotations = {
                summary       = "CPU usage is above 75%"
                description   = "This component has used at least 75% of its CPU limit for ${local.tenant_alert_warning_text}. Review its workload and consider increasing CPU capacity."
                usage_percent = "{{ printf \"%.1f\" $value }}"
              }
            },
            {
              alert  = "VTAFarmCPUUsageCritical"
              expr   = <<-PROMQL
                100 * max by (namespace, label_session_id, label_app) (
                  vtafarm:pod_cpu_usage_cores:rate${var.config.tenant_cpu_usage_window}
                  / clamp_min(vtafarm:pod_cpu_limit_cores, 0.001)
                ) >= 90
              PROMQL
              for    = var.config.tenant_alert_critical_for
              labels = { audience = "tenant", category = "resource", resource = "cpu", severity = "critical" }
              annotations = {
                summary       = "CPU usage is above 90%"
                description   = "This component has used at least 90% of its CPU limit for ${local.tenant_alert_critical_text} and may be throttled. Increase CPU capacity if the load is expected."
                usage_percent = "{{ printf \"%.1f\" $value }}"
              }
            },
            {
              alert  = "VTAFarmMemoryUsageHigh"
              expr   = <<-PROMQL
                (
                  100 * max by (namespace, label_session_id, label_app) (
                    vtafarm:pod_memory_working_set_bytes
                    / clamp_min(vtafarm:pod_memory_limit_bytes, 1)
                  ) >= 75
                ) and (
                  100 * max by (namespace, label_session_id, label_app) (
                    vtafarm:pod_memory_working_set_bytes
                    / clamp_min(vtafarm:pod_memory_limit_bytes, 1)
                  ) < 90
                )
              PROMQL
              for    = var.config.tenant_alert_warning_for
              labels = { audience = "tenant", category = "resource", resource = "memory", severity = "warning" }
              annotations = {
                summary       = "Memory usage is above 75%"
                description   = "This component has used at least 75% of its memory limit for ${local.tenant_alert_warning_text}. Review its workload and consider increasing memory capacity."
                usage_percent = "{{ printf \"%.1f\" $value }}"
              }
            },
            {
              alert  = "VTAFarmMemoryUsageCritical"
              expr   = <<-PROMQL
                100 * max by (namespace, label_session_id, label_app) (
                  vtafarm:pod_memory_working_set_bytes
                  / clamp_min(vtafarm:pod_memory_limit_bytes, 1)
                ) >= 90
              PROMQL
              for    = var.config.tenant_alert_critical_for
              labels = { audience = "tenant", category = "resource", resource = "memory", severity = "critical" }
              annotations = {
                summary       = "Memory usage is above 90%"
                description   = "This component has used at least 90% of its memory limit for ${local.tenant_alert_critical_text} and is at risk of being OOMKilled. Increase memory capacity."
                usage_percent = "{{ printf \"%.1f\" $value }}"
              }
            },
            {
              alert  = "VTAFarmStorageUsageHigh"
              expr   = <<-PROMQL
                (
                  100 * max by (namespace, label_session_id, label_app) (
                    vtafarm:pod_persistent_volume_used_bytes
                    / clamp_min(vtafarm:pod_persistent_volume_capacity_bytes, 1)
                  ) >= 75
                ) and (
                  100 * max by (namespace, label_session_id, label_app) (
                    vtafarm:pod_persistent_volume_used_bytes
                    / clamp_min(vtafarm:pod_persistent_volume_capacity_bytes, 1)
                  ) < 90
                )
              PROMQL
              for    = "15m"
              labels = { audience = "tenant", category = "resource", resource = "storage", severity = "warning" }
              annotations = {
                summary       = "Storage usage is above 75%"
                description   = "This component has used at least 75% of its persistent storage for 15 minutes. Plan a storage increase before it fills."
                usage_percent = "{{ printf \"%.1f\" $value }}"
              }
            },
            {
              alert  = "VTAFarmStorageUsageCritical"
              expr   = <<-PROMQL
                100 * max by (namespace, label_session_id, label_app) (
                  vtafarm:pod_persistent_volume_used_bytes
                  / clamp_min(vtafarm:pod_persistent_volume_capacity_bytes, 1)
                ) >= 90
              PROMQL
              for    = "5m"
              labels = { audience = "tenant", category = "resource", resource = "storage", severity = "critical" }
              annotations = {
                summary       = "Storage usage is above 90%"
                description   = "This component has used at least 90% of its persistent storage and may stop writing data. Increase storage capacity urgently."
                usage_percent = "{{ printf \"%.1f\" $value }}"
              }
            },
            {
              alert  = "VTAFarmMemoryOOMKilled"
              expr   = <<-PROMQL
                max by (namespace, label_session_id, label_app) (
                  (
                    max by (namespace, pod, container) (increase(kube_pod_container_status_restarts_total[5m])) > 0
                    and on (namespace, pod, container)
                    max by (namespace, pod, container) (kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1)
                  )
                  * on (namespace, pod) group_left(label_session_id, label_app)
                  kube_pod_labels{label_session_id!=""}
                ) > 0
              PROMQL
              labels = { audience = "tenant", category = "availability", resource = "memory", severity = "critical" }
              annotations = {
                summary     = "A container was OOMKilled"
                description = "This component reached its memory limit and Kubernetes restarted it. Related logs and the incident window are available in the VTA Farm portal."
              }
            },
            {
              alert  = "VTAFarmComponentCrashLooping"
              expr   = <<-PROMQL
                max by (namespace, label_session_id, label_app) (
                  kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"}
                  * on (namespace, pod) group_left(label_session_id, label_app)
                  kube_pod_labels{label_session_id!=""}
                ) > 0
              PROMQL
              for    = "3m"
              labels = { audience = "tenant", category = "availability", resource = "runtime", severity = "critical" }
              annotations = {
                summary     = "A component is repeatedly crashing"
                description = "Kubernetes has placed this component in CrashLoopBackOff for at least 3 minutes. Download the related logs to investigate the startup failure."
              }
            },
          ]
        }]
      }
    }
  }

  thanos_values = {
    fullnameOverride = local.thanos_release_name

    global = {
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
        enabled      = true
        storageClass = var.config.thanos_compactor_storage_class
        size         = var.config.thanos_compactor_storage_size
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
          "dnssrv+_grpc._tcp.${local.release_name}-thanos-discovery.${var.config.monitoring_namespace}.svc.cluster.local",
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
      enabled       = true
      replicaCount  = var.config.thanos_query_frontend_replicas
      downstreamUrl = local.thanos_query_url
      service = {
        type = "ClusterIP"
      }
      ingress = {
        enabled = false
      }
      cacheConfig = yamlencode({
        type = "IN-MEMORY"
        config = {
          max_size       = "256MB"
          max_size_items = 1000
          validity       = "5m"
        }
      })
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "1Gi" }
      }
      pdb = {
        enabled      = var.config.thanos_query_frontend_replicas > 1
        minAvailable = var.config.thanos_query_frontend_replicas > 1 ? 1 : ""
      }
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
        enabled      = true
        storageClass = var.config.thanos_storegateway_storage_class
        size         = var.config.thanos_storegateway_storage_size
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

  loki_values = {
    deploymentMode   = "Monolithic"
    fullnameOverride = local.loki_release_name
    global = {
      # RKE2 packages CoreDNS under this Service name rather than kube-dns,
      # which the Loki gateway otherwise writes into its nginx resolver.
      clusterDomain = "cluster.local"
      dnsService    = "rke2-coredns-rke2-coredns"
      dnsNamespace  = "kube-system"
    }
    commonLabels = {
      "app.kubernetes.io/managed-by" = "opentofu"
      "vtafarm.ic3.dev/cluster"      = var.config.cluster_name
    }

    defaults = {
      extraEnvFrom = [{
        secretRef = { name = local.loki_s3_secret_name }
      }]
    }

    loki = {
      auth_enabled = false
      commonConfig = {
        replication_factor = var.config.loki_replicas
      }
      schemaConfig = {
        configs = [{
          from         = "2024-04-01"
          store        = "tsdb"
          object_store = "s3"
          schema       = "v13"
          index = {
            prefix = "loki_index_"
            period = "24h"
          }
        }]
      }
      storage = {
        type = "s3"
        bucketNames = {
          chunks = var.config.loki_s3_chunks_bucket
          ruler  = var.config.loki_s3_ruler_bucket
        }
        use_thanos_objstore = true
        object_store = {
          type           = "s3"
          storage_prefix = var.config.loki_s3_chunks_prefix
          s3 = {
            endpoint          = var.config.loki_s3_endpoint
            region            = var.config.loki_s3_region
            access_key_id     = "$${AWS_ACCESS_KEY_ID}"
            secret_access_key = "$${AWS_SECRET_ACCESS_KEY}"
            insecure          = false
            dualstack_enabled = false
          }
        }
      }
      structuredConfig = {
        ruler_storage = {
          storage_prefix = var.config.loki_s3_ruler_prefix
        }
      }
      limits_config = {
        allow_structured_metadata  = true
        discover_log_levels        = true
        volume_enabled             = true
        retention_period           = var.config.loki_retention
        reject_old_samples         = true
        reject_old_samples_max_age = var.config.loki_retention
      }
      compactor = {
        working_directory    = "/var/loki/compactor"
        retention_enabled    = true
        delete_request_store = "s3"
      }
    }

    # A single monolithic replica must be discoverable through the headless
    # Service before its readiness probe succeeds so it can bootstrap its ring.
    memberlist = {
      service = {
        publishNotReadyAddresses = true
      }
    }

    podDisruptionBudget = { enabled = false }
    singleBinary = {
      replicas = var.config.loki_replicas
      podDisruptionBudget = {
        enabled      = var.config.loki_replicas > 1
        minAvailable = var.config.loki_replicas > 1 ? 2 : null
      }
      affinity = {
        podAntiAffinity = {
          preferredDuringSchedulingIgnoredDuringExecution = [{
            weight = 100
            podAffinityTerm = {
              labelSelector = {
                matchLabels = {
                  "app.kubernetes.io/component" = "single-binary"
                  "app.kubernetes.io/name"      = local.loki_release_name
                  "app.kubernetes.io/instance"  = local.loki_release_name
                }
              }
              topologyKey = "kubernetes.io/hostname"
            }
          }]
        }
      }
      persistence = {
        enabled                        = true
        storageClass                   = var.config.loki_storage_class
        size                           = var.config.loki_storage_size
        whenDeleted                    = "Retain"
        whenScaled                     = "Retain"
        enableStatefulSetAutoDeletePVC = false
      }
      resources = {
        requests = { cpu = "100m", memory = "512Mi" }
        limits   = { memory = "2Gi" }
      }
    }

    gateway = {
      replicas       = var.config.loki_gateway_replicas
      verboseLogging = false
      podDisruptionBudget = {
        enabled      = var.config.loki_gateway_replicas > 1
        minAvailable = var.config.loki_gateway_replicas > 1 ? 1 : null
      }
      resources = {
        requests = { cpu = "25m", memory = "64Mi" }
        limits   = { memory = "256Mi" }
      }
    }

    chunksCache  = { enabled = false }
    resultsCache = { enabled = false }
    monitoring = {
      serviceMonitor = {
        enabled  = true
        interval = var.config.scrape_interval
      }
      dashboards = { enabled = true }
      rules      = { enabled = true }
      alerts     = { enabled = true }
      additionalPrometheusRules = {
        "vtafarm-logging" = {
          groups = [{
            name = "vtafarm.logging"
            rules = [
              {
                alert  = "VTAFarmAlloyUnavailable"
                expr   = "kube_daemonset_status_number_unavailable{namespace=\"${var.config.logging_namespace}\",daemonset=\"${local.alloy_release_name}\"} > 0"
                for    = "5m"
                labels = { severity = "warning" }
                annotations = {
                  summary = "Alloy is not ready on every cluster node"
                }
              },
              {
                alert  = "VTAFarmLokiReplicaUnavailable"
                expr   = "kube_statefulset_status_replicas_ready{namespace=\"${var.config.logging_namespace}\",statefulset=\"${local.loki_release_name}\"} < ${var.config.loki_replicas}"
                for    = "5m"
                labels = { severity = "warning" }
                annotations = {
                  summary = "One or more Loki replicas are unavailable"
                }
              },
              {
                alert  = "VTAFarmLokiGatewayUnavailable"
                expr   = "kube_deployment_status_replicas_available{namespace=\"${var.config.logging_namespace}\",deployment=\"${local.loki_release_name}-gateway\"} < 1"
                for    = "5m"
                labels = { severity = "critical" }
                annotations = {
                  summary = "The Loki gateway has no available replica"
                }
              },
              {
                alert  = "VTAFarmLokiPVCUsageHigh"
                expr   = "kubelet_volume_stats_used_bytes{namespace=\"${var.config.logging_namespace}\",persistentvolumeclaim=~\"storage-${local.loki_release_name}-.*\"} / kubelet_volume_stats_capacity_bytes{namespace=\"${var.config.logging_namespace}\",persistentvolumeclaim=~\"storage-${local.loki_release_name}-.*\"} > 0.85"
                for    = "15m"
                labels = { severity = "critical" }
                annotations = {
                  summary = "A Loki working volume is more than 85% full"
                }
              },
            ]
          }]
        }
      }
    }

    backend        = { replicas = 0 }
    read           = { replicas = 0 }
    write          = { replicas = 0 }
    ingester       = { replicas = 0 }
    querier        = { replicas = 0 }
    queryFrontend  = { replicas = 0 }
    queryScheduler = { replicas = 0 }
    distributor    = { replicas = 0 }
    compactor      = { replicas = 0 }
    indexGateway   = { replicas = 0 }
    bloomPlanner   = { replicas = 0 }
    bloomBuilder   = { replicas = 0 }
    bloomGateway   = { replicas = 0 }
  }

  alloy_config = <<-ALLOY
    discovery.kubernetes "pods" {
      role = "pod"

      selectors {
        role  = "pod"
        field = "spec.nodeName=" + sys.env("K8S_NODE_NAME")
      }
    }

    discovery.relabel "pod_logs" {
      targets = discovery.kubernetes.pods.targets

      rule {
        source_labels = ["__meta_kubernetes_namespace"]
        target_label  = "namespace"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
        target_label  = "app"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_label_app"]
        regex         = "(.+)"
        target_label  = "app"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_container_name"]
        target_label  = "container"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_name"]
        target_label  = "pod"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_uid"]
        target_label  = "pod_uid"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_node_name"]
        target_label  = "node"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_label_session_id"]
        target_label  = "session_id"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
        separator     = "/"
        replacement   = "/var/log/pods/*$1/*.log"
        target_label  = "__path__"
      }
      rule {
        source_labels = ["__meta_kubernetes_pod_container_id"]
        regex         = "^(\\w+):\\/\\/.+$"
        replacement   = "$1"
        target_label  = "tmp_container_runtime"
      }
    }

    local.file_match "pod_logs" {
      path_targets = discovery.relabel.pod_logs.output
    }

    loki.source.file "pod_logs" {
      targets    = local.file_match.pod_logs.targets
      forward_to = [loki.process.pod_logs.receiver]
    }

    loki.process "pod_logs" {
      stage.match {
        selector = "{tmp_container_runtime=\"containerd\"}"
        stage.cri {}
      }

      stage.match {
        selector = "{tmp_container_runtime=\"docker\"}"
        stage.docker {}
      }

      stage.static_labels {
        values = {
          cluster = "${var.config.cluster_name}",
        }
      }

      stage.structured_metadata {
        values = {
          pod        = "",
          pod_uid    = "",
          node       = "",
          session_id = "",
        }
      }

      stage.label_keep {
        values = ["cluster", "namespace", "app", "container"]
      }

      forward_to = [loki.write.default.receiver]
    }

    loki.write "default" {
      endpoint {
        url = "${local.loki_gateway_url}/loki/api/v1/push"
      }
    }
  ALLOY

  alloy_values = {
    fullnameOverride = local.alloy_release_name
    global = {
      podSecurityContext = {}
    }
    crds = { create = false }
    alloy = {
      configMap = {
        create  = true
        content = local.alloy_config
      }
      clustering      = { enabled = false }
      storagePath     = "/var/lib/alloy"
      enableReporting = false
      mounts = {
        varlog = true
        extra = [{
          name      = "alloy-storage"
          mountPath = "/var/lib/alloy"
        }]
      }
      securityContext = {
        runAsUser                = 0
        runAsGroup               = 0
        allowPrivilegeEscalation = false
        readOnlyRootFilesystem   = true
        capabilities             = { drop = ["ALL"] }
      }
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "512Mi" }
      }
    }
    controller = {
      type        = "daemonset"
      tolerations = [{ operator = "Exists" }]
      updateStrategy = {
        type          = "RollingUpdate"
        rollingUpdate = { maxUnavailable = 1 }
      }
      volumes = {
        extra = [{
          name = "alloy-storage"
          hostPath = {
            path = "/var/lib/alloy"
            type = "DirectoryOrCreate"
          }
        }]
      }
    }
    rbac = {
      create = true
      rules = [{
        apiGroups = [""]
        resources = ["pods"]
        verbs     = ["get", "list", "watch"]
      }]
      # The chart concatenates both lists without guarding an empty second
      # list, so repeat the same least-privilege rule instead of rendering an
      # invalid trailing `[]` in the ClusterRole.
      clusterRules = [{
        apiGroups = [""]
        resources = ["pods"]
        verbs     = ["get", "list", "watch"]
      }]
    }
    service = {
      enabled = true
      type    = "ClusterIP"
    }
    serviceMonitor = {
      enabled  = true
      interval = var.config.scrape_interval
    }
    ingress = { enabled = false }
  }
}

resource "kubernetes_namespace_v1" "monitoring" {
  count = var.config.enabled ? 1 : 0

  metadata {
    name = var.config.monitoring_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "opentofu"
      "vtafarm.ic3.dev/purpose"      = "observability"
    }
  }
}

resource "kubernetes_namespace_v1" "logging" {
  count = var.config.enabled && var.config.loki_enabled ? 1 : 0

  metadata {
    name = var.config.logging_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "opentofu"
      "vtafarm.ic3.dev/purpose"      = "logging"
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

resource "kubernetes_secret_v1" "loki_s3" {
  count = var.config.enabled && var.config.loki_enabled ? 1 : 0

  metadata {
    name      = local.loki_s3_secret_name
    namespace = kubernetes_namespace_v1.logging[0].metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "opentofu"
      "vtafarm.ic3.dev/cluster"      = var.config.cluster_name
    }
  }

  type = "Opaque"
  data = {
    AWS_ACCESS_KEY_ID     = var.config.loki_s3_access_key
    AWS_SECRET_ACCESS_KEY = var.config.loki_s3_secret_key
  }
}

resource "kubernetes_secret_v1" "alertmanager_webhook" {
  count = var.config.enabled && var.config.alertmanager_webhook_enabled ? 1 : 0

  metadata {
    name      = var.config.alertmanager_webhook_secret_name
    namespace = kubernetes_namespace_v1.monitoring[0].metadata[0].name
    labels = {
      "app.kubernetes.io/managed-by" = "opentofu"
      "vtafarm.ic3.dev/cluster"      = var.config.cluster_name
    }
  }

  type = "Opaque"
  data_wo = {
    ALERTMANAGER_WEBHOOK_TOKEN = var.alertmanager_webhook_token
  }
  data_wo_revision = var.config.alertmanager_webhook_token_revision

  lifecycle {
    precondition {
      condition     = length(trimspace(var.alertmanager_webhook_token)) >= 32
      error_message = "alertmanager_webhook_token must contain at least 32 characters when the webhook is enabled."
    }
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
    kubernetes_secret_v1.alertmanager_webhook,
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

resource "helm_release" "loki" {
  count = var.config.enabled && var.config.loki_enabled ? 1 : 0

  name      = local.loki_release_name
  chart     = "oci://ghcr.io/grafana-community/helm-charts/loki"
  version   = var.config.loki_chart_version
  namespace = kubernetes_namespace_v1.logging[0].metadata[0].name

  values = [yamlencode(local.loki_values)]

  wait    = true
  timeout = 900

  depends_on = [
    helm_release.kube_prometheus_stack,
    kubernetes_secret_v1.loki_s3,
  ]
}

resource "helm_release" "alloy" {
  count = var.config.enabled && var.config.loki_enabled ? 1 : 0

  name      = local.alloy_release_name
  chart     = "oci://ghcr.io/grafana/helm-charts/alloy"
  version   = var.config.alloy_chart_version
  namespace = kubernetes_namespace_v1.logging[0].metadata[0].name

  values = [yamlencode(local.alloy_values)]

  wait    = true
  timeout = 900

  depends_on = [helm_release.loki]
}

# Rancher project isolation does not admit traffic from the observability
# namespace, so Alertmanager needs an explicit path to the internal webhook.
resource "kubernetes_network_policy_v1" "alertmanager_webhook" {
  count = var.config.alertmanager_webhook_enabled ? 1 : 0

  metadata {
    name      = "vtafarm-api-alertmanager-webhook"
    namespace = var.config.namespace
  }

  spec {
    pod_selector {
      match_labels = {
        app = "vtafarm-api"
      }
    }

    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = {
            "vtafarm.ic3.dev/purpose" = "observability"
          }
        }

        pod_selector {
          match_labels = {
            "app.kubernetes.io/name" = "alertmanager"
          }
        }
      }

      ports {
        port     = "8080"
        protocol = "TCP"
      }
    }
  }
}

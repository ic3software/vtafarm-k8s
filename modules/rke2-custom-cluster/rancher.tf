data "rancher2_setting" "agent_tls_mode" {
  name = "agent-tls-mode"
}

data "rancher2_setting" "cacerts" {
  name = "cacerts"
}

resource "rancher2_cluster_v2" "this" {
  name                  = var.config.cluster_name
  kubernetes_version    = var.config.rke2_version
  enable_network_policy = true

  local_auth_endpoint {
    enabled = true
    fqdn    = var.config.api_hostname != "" ? var.config.api_hostname : null
  }

  rke_config {
    machine_global_config = local.machine_global_config
    additional_manifest   = sensitive(local.additional_manifest)
    chart_values          = local.chart_values

    upgrade_strategy {
      control_plane_concurrency = var.config.control_plane_upgrade_concurrency
      worker_concurrency        = var.config.worker_upgrade_concurrency

      control_plane_drain_options {
        enabled                              = true
        delete_empty_dir_data                = false
        ignore_daemon_sets                   = true
        timeout                              = 300
        skip_wait_for_delete_timeout_seconds = 60
      }

      worker_drain_options {
        enabled                              = true
        delete_empty_dir_data                = false
        ignore_daemon_sets                   = true
        timeout                              = 300
        skip_wait_for_delete_timeout_seconds = 60
      }
    }
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

  lifecycle {
    precondition {
      condition = (
        trimspace(data.rancher2_setting.agent_tls_mode.value) == "system-store" ||
        trimspace(data.rancher2_setting.cacerts.value) != ""
      )
      error_message = "Rancher agent TLS is strict but the cacerts setting is empty. Apply stack 02 with agentTLSMode=system-store for a public CA, or configure the private CA in Rancher, before creating RKE2 nodes."
    }
  }
}

mock_provider "hcloud" {}
mock_provider "rancher2" {}

run "default_ha_topology" {
  command = plan

  override_data {
    target = data.rancher2_setting.agent_tls_mode
    values = { value = "system-store" }
  }

  override_data {
    target = data.rancher2_setting.cacerts
    values = { value = "" }
  }

  variables {
    config = {
      cluster_name = "production"
      ssh_key_name = "k3s-rancher-admin"
    }
    hcloud_token = "test-token"
  }

  override_resource {
    target = rancher2_cluster_v2.this
    values = {
      cluster_registration_token = [{
        annotations                   = {}
        cluster_id                    = "fleet-default/production"
        command                       = ""
        id                            = "token-id"
        insecure_command              = ""
        insecure_node_command         = ""
        insecure_windows_node_command = ""
        labels                        = {}
        manifest_url                  = ""
        name                          = "production-token"
        node_command                  = "curl -fsSL https://rancher.example.com/system-agent-install.sh | sh -s -"
        token                         = "registration-token"
        windows_node_command          = ""
      }]
    }
  }

  assert {
    condition     = length(hcloud_server.node) == 3
    error_message = "The default topology must create exactly three server nodes."
  }

  assert {
    condition     = alltrue([for node in local.server_nodes : node.roles == ["etcd", "controlplane", "worker"]])
    error_message = "Default server nodes must carry all three Rancher roles."
  }

  assert {
    condition     = local.nodes["server-1"].private_ip == "10.10.1.101"
    error_message = "Server private addresses must remain deterministic."
  }

  assert {
    condition = (
      hcloud_load_balancer_service.ingress_http.listen_port == 80 &&
      hcloud_load_balancer_service.ingress_http.destination_port == 80 &&
      hcloud_load_balancer_service.ingress_https.listen_port == 443 &&
      hcloud_load_balancer_service.ingress_https.destination_port == 443
    )
    error_message = "The load balancer must expose standard HTTP and HTTPS ports to the ingress controller."
  }
}

run "worker_scale_does_not_renumber_servers" {
  command = plan

  override_data {
    target = data.rancher2_setting.agent_tls_mode
    values = { value = "system-store" }
  }

  override_data {
    target = data.rancher2_setting.cacerts
    values = { value = "" }
  }

  variables {
    config = {
      cluster_name = "production"
      ssh_key_name = "k3s-rancher-admin"
      server_type  = "cx33"
      worker_count = 2
      worker_type  = "cx43"
    }
    hcloud_token = "test-token"
  }

  override_resource {
    target = rancher2_cluster_v2.this
    values = {
      cluster_registration_token = [{
        annotations                   = {}
        cluster_id                    = "fleet-default/production"
        command                       = ""
        id                            = "token-id"
        insecure_command              = ""
        insecure_node_command         = ""
        insecure_windows_node_command = ""
        labels                        = {}
        manifest_url                  = ""
        name                          = "production-token"
        node_command                  = "curl -fsSL https://rancher.example.com/system-agent-install.sh | sh -s -"
        token                         = "registration-token"
        windows_node_command          = ""
      }]
    }
  }

  assert {
    condition     = length(hcloud_server.node) == 5
    error_message = "Two workers should add nodes without replacing the three servers."
  }

  assert {
    condition     = local.nodes["server-1"].private_ip == "10.10.1.101" && local.nodes["worker-1"].private_ip == "10.10.1.151"
    error_message = "Server and worker address ranges must stay independent."
  }

  assert {
    condition = (
      hcloud_server.node["server-1"].server_type == "cx33" &&
      hcloud_server.node["worker-1"].server_type == "cx43"
    )
    error_message = "Server and worker node types must honor their independent configuration values."
  }
}

run "rejects_strict_tls_without_cacerts" {
  command = plan

  override_data {
    target = data.rancher2_setting.agent_tls_mode
    values = { value = "strict" }
  }

  override_data {
    target = data.rancher2_setting.cacerts
    values = { value = "" }
  }

  variables {
    config = {
      cluster_name = "production"
      ssh_key_name = "k3s-rancher-admin"
    }
    hcloud_token = "test-token"
  }

  override_resource {
    target = rancher2_cluster_v2.this
    values = {
      cluster_registration_token = [{
        annotations                   = {}
        cluster_id                    = "fleet-default/production"
        command                       = ""
        id                            = "token-id"
        insecure_command              = ""
        insecure_node_command         = ""
        insecure_windows_node_command = ""
        labels                        = {}
        manifest_url                  = ""
        name                          = "production-token"
        node_command                  = "curl -fsSL https://rancher.example.com/system-agent-install.sh | sh -s -"
        token                         = "registration-token"
        windows_node_command          = ""
      }]
    }
  }

  expect_failures = [rancher2_cluster_v2.this]
}

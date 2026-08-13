mock_provider "hcloud" {}
mock_provider "rancher2" {}

run "default_ha_topology" {
  command = plan

  variables {
    config = {
      cluster_name = "production"
      ssh_key_name = "existing-admin-key"
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
}

run "worker_scale_does_not_renumber_servers" {
  command = plan

  variables {
    config = {
      cluster_name = "production"
      ssh_key_name = "existing-admin-key"
      worker_count = 2
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
}

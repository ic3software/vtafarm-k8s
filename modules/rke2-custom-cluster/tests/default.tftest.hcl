# Hetzner ids are numbers, and firewall_id/network_id/server_id/... are typed
# that way. Left to itself the mock invents a random alphanumeric id for every
# resource, which then fails to convert. Give it ids the API could return.
mock_provider "hcloud" {
  mock_resource "hcloud_firewall" {
    defaults = { id = "1" }
  }
  mock_resource "hcloud_network" {
    defaults = { id = "2" }
  }
  mock_resource "hcloud_load_balancer" {
    defaults = { id = "3" }
  }
  mock_resource "hcloud_placement_group" {
    defaults = { id = "4" }
  }
  mock_resource "hcloud_server" {
    defaults = {
      id           = "5"
      ipv4_address = "203.0.113.10"
    }
  }
}

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
    condition     = alltrue([for node in hcloud_server.node : node.server_type == "cx33"])
    error_message = "The default RKE2 server type must be cx33."
  }

  assert {
    condition     = alltrue([for node in local.server_nodes : node.roles == ["etcd", "controlplane", "worker"]])
    error_message = "Default server nodes must carry all three Rancher roles."
  }

  assert {
    condition = (
      rancher2_cluster_v2.this.rke_config[0].upgrade_strategy[0].control_plane_drain_options[0].delete_empty_dir_data == false &&
      rancher2_cluster_v2.this.rke_config[0].upgrade_strategy[0].worker_drain_options[0].delete_empty_dir_data == false
    )
    error_message = "Drain options must preserve emptyDir data unless a cluster explicitly opts in."
  }

  assert {
    condition     = local.nodes["server-1"].private_ip == "10.10.1.101"
    error_message = "Server private addresses must remain deterministic."
  }

  assert {
    condition = (
      strcontains(
        base64decode(one([
          for config in yamldecode(local.node_user_data["server-1"]).write_files : config.content
          if config.path == "/etc/rancher-node-bootstrap.env"
        ])),
        "PRIVATE_NETWORK_CIDR=\"10.10.0.0/16\"",
      ) &&
      strcontains(
        base64decode(one([
          for config in yamldecode(local.node_user_data["server-1"]).write_files : config.content
          if config.path == "/etc/rancher-node-bootstrap.env"
        ])),
        "PRIVATE_NETWORK_GATEWAY=\"10.10.0.1\"",
      ) &&
      strcontains(
        base64decode(one([
          for config in yamldecode(local.node_user_data["server-1"]).write_files : config.content
          if config.path == "/usr/local/bin/rancher-node-bootstrap.sh"
        ])),
        "use-routes: false",
      ) &&
      strcontains(
        base64decode(one([
          for config in yamldecode(local.node_user_data["server-1"]).write_files : config.content
          if config.path == "/usr/local/bin/rancher-node-bootstrap.sh"
        ])),
        "to: $${PRIVATE_NETWORK_CIDR}",
      ) &&
      strcontains(
        base64decode(one([
          for config in yamldecode(local.node_user_data["server-1"]).write_files : config.content
          if config.path == "/usr/local/bin/rancher-node-bootstrap.sh"
        ])),
        "to: $${PRIVATE_NETWORK_GATEWAY}/32",
      )
    )
    error_message = "Private NIC bootstrap must reject DHCP routes and install the configured network route explicitly."
  }

  assert {
    condition = (
      hcloud_load_balancer_service.ingress_http[0].listen_port == 80 &&
      hcloud_load_balancer_service.ingress_http[0].destination_port == 80 &&
      hcloud_load_balancer_service.ingress_https[0].listen_port == 443 &&
      hcloud_load_balancer_service.ingress_https[0].destination_port == 443
    )
    error_message = "The load balancer must expose standard HTTP and HTTPS ports to the ingress controller."
  }

  # A public-NIC flannel binding is silent until pods land on different nodes,
  # so pin it here rather than wait for cross-node traffic to fail.
  assert {
    condition = (
      strcontains(local.additional_manifest, local.canal_manifest) &&
      can(regex(
        yamldecode(yamldecode(local.canal_manifest).spec.valuesContent).flannel.regexIface,
        local.nodes["server-1"].private_ip,
      )) &&
      yamldecode(yamldecode(local.canal_manifest).spec.valuesContent).calico.vethuMTU == 1400
    )
    error_message = "Canal must bind flannel to the private interface, with a pod MTU that matches its VXLAN tunnel."
  }

  # A metadata request routed through the private NIC times out and leaves the
  # external-cloud-provider taint in place, so no ordinary pod can schedule.
  assert {
    condition = (
      yamldecode(yamldecode(local.hcloud_ccm_manifest).spec.valuesContent).env.HCLOUD_NETWORK_DISABLE_ATTACHED_CHECK.value == "true" &&
      yamldecode(yamldecode(local.hcloud_ccm_manifest).spec.valuesContent).env.HCLOUD_NETWORK_ROUTES_ENABLED.value == "false"
    )
    error_message = "The Hetzner CCM must trust OpenTofu's network attachment and leave private-network routing to Canal."
  }
}

run "dev_single_node_topology" {
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
      cluster_name      = "development"
      dev               = true
      ssh_key_name      = "k3s-rancher-admin"
      ssh_allowed_cidrs = ["0.0.0.0/0"]
      server_count      = 8
      server_type       = "cx43"
      worker_count      = 3
      worker_type       = "cx53"
    }
    hcloud_token = "test-token"
  }

  override_resource {
    target = rancher2_cluster_v2.this
    values = {
      cluster_registration_token = [{
        annotations                   = {}
        cluster_id                    = "fleet-default/development"
        command                       = ""
        id                            = "token-id"
        insecure_command              = ""
        insecure_node_command         = ""
        insecure_windows_node_command = ""
        labels                        = {}
        manifest_url                  = ""
        name                          = "development-token"
        node_command                  = "curl -fsSL https://rancher.example.com/system-agent-install.sh | sh -s -"
        token                         = "registration-token"
        windows_node_command          = ""
      }]
    }
  }

  assert {
    condition = (
      length(hcloud_server.node) == 1 &&
      hcloud_server.node["server-1"].server_type == "cx43" &&
      local.server_nodes["server-1"].roles == ["etcd", "controlplane", "worker"]
    )
    error_message = "Dev must create exactly one all-in-one node using server_type."
  }

  assert {
    condition = (
      length(hcloud_network.this) == 0 &&
      length(hcloud_network_subnet.nodes) == 0 &&
      length(hcloud_placement_group.nodes) == 0 &&
      length(hcloud_load_balancer.api) == 0 &&
      length(hcloud_load_balancer_network.api) == 0 &&
      length(hcloud_load_balancer_target.servers) == 0 &&
      length(hcloud_load_balancer_service.kubernetes_api) == 0 &&
      length(hcloud_load_balancer_service.rke2_supervisor) == 0 &&
      length(hcloud_load_balancer_service.ingress_http) == 0 &&
      length(hcloud_load_balancer_service.ingress_https) == 0
    )
    error_message = "Dev must not create a private network, placement group, or load balancer."
  }

  assert {
    condition = (
      length(hcloud_server.node["server-1"].network) == 0 &&
      hcloud_server.node["server-1"].placement_group_id == null &&
      strcontains(
        base64decode(one([
          for config in yamldecode(local.node_user_data["server-1"]).write_files : config.content
          if config.path == "/etc/rancher-node-bootstrap.env"
        ])),
        "USE_PRIVATE_NETWORK=\"false\"",
      ) &&
      !strcontains(
        base64decode(one([
          for config in yamldecode(local.node_user_data["server-1"]).write_files : config.content
          if config.path == "/etc/rancher/node-registration.sh"
        ])),
        "--internal-address",
      )
    )
    error_message = "Dev bootstrap must use only the public NIC and let Rancher detect its address."
  }

  assert {
    condition = (
      length(hcloud_firewall.nodes.rule) == 5 &&
      anytrue([
        for rule in hcloud_firewall.nodes.rule :
        rule.port == "6443" && rule.source_ips == toset(["0.0.0.0/0"])
      ]) &&
      alltrue([
        for port in ["80", "443"] : anytrue([
          for rule in hcloud_firewall.nodes.rule :
          rule.port == port && rule.source_ips == toset(["0.0.0.0/0"])
        ])
      ])
    )
    error_message = "Dev firewall must expose SSH, the API, HTTP, and HTTPS while leaving other ports closed."
  }

  assert {
    condition = (
      !strcontains(local.additional_manifest, local.canal_manifest) &&
      !can(yamldecode(yamldecode(local.hcloud_ccm_manifest).spec.valuesContent).env) &&
      yamldecode(local.chart_values)["rke2-traefik"].deployment.kind == "DaemonSet" &&
      yamldecode(local.chart_values)["rke2-traefik"].service.spec.type == "ClusterIP" &&
      yamldecode(local.chart_values)["rke2-traefik"].ports.web.hostPort == 80 &&
      yamldecode(local.chart_values)["rke2-traefik"].ports.websecure.hostPort == 443 &&
      output.load_balancer_ipv4 == null &&
      output.kubernetes_api_endpoint == "https://203.0.113.10:6443"
    )
    error_message = "Dev manifests, ingress, and outputs must not depend on a private network or load balancer."
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
      cluster_name                        = "production"
      ssh_key_name                        = "k3s-rancher-admin"
      server_type                         = "cx33"
      worker_count                        = 2
      worker_type                         = "cx43"
      control_plane_delete_empty_dir_data = true
      worker_delete_empty_dir_data        = true
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

  assert {
    condition = (
      rancher2_cluster_v2.this.rke_config[0].upgrade_strategy[0].control_plane_drain_options[0].delete_empty_dir_data == true &&
      rancher2_cluster_v2.this.rke_config[0].upgrade_strategy[0].worker_drain_options[0].delete_empty_dir_data == true
    )
    error_message = "Clusters must be able to opt in to deleting emptyDir data for each node role."
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

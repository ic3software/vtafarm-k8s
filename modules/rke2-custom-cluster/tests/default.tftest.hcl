# Hetzner ids are numbers, and firewall_id/network_id/server_id/... are typed
# that way. Left to itself the mock invents a random alphanumeric id for every
# resource, which then fails to convert. Give it ids the API could return.
mock_provider "hcloud" {
  mock_data "hcloud_server_type" {
    defaults = {
      locations = [
        {
          available             = true
          deprecation_announced = ""
          id                    = 1
          is_deprecated         = false
          name                  = "fsn1"
          recommended           = true
          unavailable_after     = ""
        },
        {
          available             = true
          deprecation_announced = ""
          id                    = 2
          is_deprecated         = false
          name                  = "nbg1"
          recommended           = true
          unavailable_after     = ""
        },
        {
          available             = true
          deprecation_announced = ""
          id                    = 3
          is_deprecated         = false
          name                  = "hel1"
          recommended           = true
          unavailable_after     = ""
        },
      ]
    }
  }

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
    condition = terraform_data.retired_nodes.triggers_replace.nodes == tolist([
      "production-server-1", "production-server-2", "production-server-3",
    ])
    error_message = "Retirement reconciliation must track the desired server nodes."
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
    condition     = !contains(keys(yamldecode(local.machine_global_config)), "write-kubeconfig-mode")
    error_message = "The RKE2 machine plan must rely on the secure default kubeconfig mode to avoid metadata-driven plan churn."
  }

  assert {
    condition     = !contains(keys(yamldecode(local.machine_global_config)), "kubelet-arg")
    error_message = "Kubelet reservations must remain opt-in for existing clusters."
  }

  assert {
    condition     = length(rancher2_cluster_v2.this.rke_config[0].machine_selector_config) == 0
    error_message = "Default clusters must not render a machine selector without scoped kubelet reservations."
  }

  assert {
    condition     = length(rancher2_cluster_v2.this.cluster_agent_deployment_customization) == 0
    error_message = "Default clusters must not override Rancher cluster-agent resources."
  }

  assert {
    condition = (
      rancher2_cluster_v2.this.rke_config[0].upgrade_strategy[0].control_plane_drain_options[0].timeout == 1800 &&
      rancher2_cluster_v2.this.rke_config[0].upgrade_strategy[0].worker_drain_options[0].timeout == 1800 &&
      rancher2_cluster_v2.this.rke_config[0].upgrade_strategy[0].control_plane_drain_options[0].delete_empty_dir_data == false &&
      rancher2_cluster_v2.this.rke_config[0].upgrade_strategy[0].worker_drain_options[0].delete_empty_dir_data == false
    )
    error_message = "Drain options must allow Longhorn 30 minutes and preserve emptyDir data unless a cluster explicitly opts in."
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

run "dev_workers_without_load_balancer" {
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
      length(hcloud_server.node) == 4 &&
      hcloud_server.node["server-1"].server_type == "cx43" &&
      local.server_nodes["server-1"].roles == ["etcd", "controlplane", "worker"] &&
      alltrue([
        for key in ["worker-1", "worker-2", "worker-3"] :
        hcloud_server.node[key].server_type == "cx53" &&
        local.worker_nodes[key].roles == ["worker"] &&
        local.worker_nodes[key].location == "nbg1"
      ])
    )
    error_message = "Dev must keep one all-in-one server and honor dedicated worker_count on worker_type in the server location."
  }

  assert {
    condition = (
      length(hcloud_network.this) == 1 &&
      length(hcloud_network_subnet.nodes) == 1 &&
      length(hcloud_placement_group.nodes) == 0 &&
      length(hcloud_load_balancer.api) == 0 &&
      length(hcloud_load_balancer_network.api) == 0 &&
      length(hcloud_load_balancer_target.servers) == 0 &&
      length(hcloud_load_balancer_service.kubernetes_api) == 0 &&
      length(hcloud_load_balancer_service.rke2_supervisor) == 0 &&
      length(hcloud_load_balancer_service.ingress_http) == 0 &&
      length(hcloud_load_balancer_service.ingress_https) == 0
    )
    error_message = "Multi-node dev must create its private node network without a placement group or load balancer."
  }

  assert {
    condition = (
      alltrue([
        for key in keys(local.nodes) :
        length(hcloud_server.node[key].network) == 1 &&
        one(hcloud_server.node[key].network).ip == local.nodes[key].private_ip &&
        hcloud_server.node[key].placement_group_id == null &&
        strcontains(
          base64decode(one([
            for config in yamldecode(local.node_user_data[key]).write_files : config.content
            if config.path == "/etc/rancher-node-bootstrap.env"
          ])),
          "USE_PRIVATE_NETWORK=\"true\"",
        ) &&
        strcontains(
          base64decode(one([
            for config in yamldecode(local.node_user_data[key]).write_files : config.content
            if config.path == "/etc/rancher/node-registration.sh"
          ])),
          "--internal-address",
        ) &&
        (
          key == "server-1" ||
          base64decode(one([
            for config in yamldecode(local.node_user_data[key]).write_files : config.content
            if config.path == "/etc/rancher/rke2/config.yaml.d/99-private-supervisor.yaml"
          ])) == "server: \"https://10.10.1.101:9345\"\n"
        )
      ])
    )
    error_message = "Every multi-node dev machine must be created on the private network and register that internal address without a placement group."
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
      strcontains(local.additional_manifest, local.canal_manifest) &&
      !strcontains(local.additional_manifest, "--kubelet-insecure-tls") &&
      !can(yamldecode(local.machine_global_config)["kube-apiserver-arg"]) &&
      yamldecode(yamldecode(local.hcloud_ccm_manifest).spec.valuesContent).env.HCLOUD_NETWORK_DISABLE_ATTACHED_CHECK.value == "true" &&
      yamldecode(local.chart_values)["rke2-traefik"].deployment.kind == "DaemonSet" &&
      yamldecode(local.chart_values)["rke2-traefik"].service.spec.type == "ClusterIP" &&
      yamldecode(local.chart_values)["rke2-traefik"].ports.web.hostPort == 80 &&
      yamldecode(local.chart_values)["rke2-traefik"].ports.websecure.hostPort == 443 &&
      output.load_balancer_ipv4 == null &&
      output.kubernetes_api_endpoint == "https://203.0.113.10:6443"
    )
    error_message = "Multi-node dev must use private-node manifests while keeping ingress and API outputs independent of a load balancer."
  }
}

run "dev_zero_workers_keeps_private_network" {
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
      server_type       = "cx33"
      worker_count      = 0
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
      length(hcloud_network.this) == 1 &&
      length(hcloud_network_subnet.nodes) == 1 &&
      length(hcloud_load_balancer.api) == 0 &&
      length(hcloud_server.node["server-1"].network) == 1 &&
      one(hcloud_server.node["server-1"].network).ip == "10.10.1.101" &&
      strcontains(
        base64decode(one([
          for config in yamldecode(local.node_user_data["server-1"]).write_files : config.content
          if config.path == "/etc/rancher/node-registration.sh"
        ])),
        "--internal-address",
      ) &&
      !can(yamldecode(local.machine_global_config)["kube-apiserver-arg"]) &&
      output.kubernetes_api_endpoint == "https://203.0.113.10:6443"
    )
    error_message = "Dev must keep its private network when worker_count is zero without adding a load balancer."
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
      worker_auto_location                = true
      control_plane_delete_empty_dir_data = true
      worker_delete_empty_dir_data        = true
      kube_reserved_cpu                   = "250m"
      kube_reserved_memory                = "512Mi"
      system_reserved_cpu                 = "250m"
      system_reserved_memory              = "512Mi"
      eviction_hard_memory_available      = "1Gi"
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
    condition = terraform_data.retired_nodes.triggers_replace.nodes == tolist([
      "production-server-1", "production-server-2", "production-server-3",
      "production-worker-1", "production-worker-2",
    ])
    error_message = "Worker count changes must also trigger retirement reconciliation."
  }

  assert {
    condition     = local.nodes["server-1"].private_ip == "10.10.1.101" && local.nodes["worker-1"].private_ip == "10.10.1.151"
    error_message = "Server and worker address ranges must stay independent."
  }

  assert {
    condition = (
      hcloud_server.node["server-1"].server_type == "cx33" &&
      hcloud_server.node["worker-1"].server_type == "cx43" &&
      hcloud_server.node["server-1"].location == "nbg1" &&
      local.nodes["worker-1"].location == null &&
      local.nodes["worker-2"].location == null
    )
    error_message = "Server and worker node types must remain independent, and worker locations must be left to Hetzner."
  }

  assert {
    condition = (
      rancher2_cluster_v2.this.rke_config[0].upgrade_strategy[0].control_plane_drain_options[0].delete_empty_dir_data == true &&
      rancher2_cluster_v2.this.rke_config[0].upgrade_strategy[0].worker_drain_options[0].delete_empty_dir_data == true
    )
    error_message = "Clusters must be able to opt in to deleting emptyDir data for each node role."
  }

  assert {
    condition = yamldecode(rancher2_cluster_v2.this.rke_config[0].machine_global_config)["kubelet-arg"] == [
      "kube-reserved=cpu=250m,memory=512Mi",
      "system-reserved=cpu=250m,memory=512Mi",
      "eviction-hard=memory.available<1Gi,nodefs.available<10%,imagefs.available<15%,nodefs.inodesFree<5%,imagefs.inodesFree<5%",
    ]
    error_message = "Rancher machineGlobalConfig must render typed kubelet reservations without dropping the default filesystem eviction thresholds."
  }
}

run "pins_workers_to_cluster_location" {
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
      worker_count = 1
      worker_type  = "cx33"
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
    condition = (
      length(data.hcloud_server_type.worker) == 0 &&
      local.nodes["worker-1"].location == "nbg1" &&
      hcloud_server.node["worker-1"].location == "nbg1"
    )
    error_message = "Disabling automatic placement must pin every worker to the cluster location."
  }
}

run "scopes_kubelet_reservations_to_canary_nodes" {
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
      cluster_name                   = "staging"
      ssh_key_name                   = "k3s-rancher-admin"
      kube_reserved_cpu              = "250m"
      kube_reserved_memory           = "256Mi"
      system_reserved_cpu            = "250m"
      system_reserved_memory         = "256Mi"
      eviction_hard_memory_available = "512Mi"
      kubelet_reservation_node_names = ["staging-server-1"]
    }
    hcloud_token = "test-token"
  }

  override_resource {
    target = rancher2_cluster_v2.this
    values = {
      cluster_registration_token = [{
        annotations                   = {}
        cluster_id                    = "fleet-default/staging"
        command                       = ""
        id                            = "token-id"
        insecure_command              = ""
        insecure_node_command         = ""
        insecure_windows_node_command = ""
        labels                        = {}
        manifest_url                  = ""
        name                          = "staging-token"
        node_command                  = "curl -fsSL https://rancher.example.com/system-agent-install.sh | sh -s -"
        token                         = "registration-token"
        windows_node_command          = ""
      }]
    }
  }

  assert {
    condition     = !contains(keys(yamldecode(rancher2_cluster_v2.this.rke_config[0].machine_global_config)), "kubelet-arg")
    error_message = "Canary kubelet reservations must not leak into Rancher's cluster-wide machine config."
  }

  assert {
    condition = yamldecode(rancher2_cluster_v2.this.rke_config[0].machine_selector_config[0].config)["kubelet-arg"] == [
      "kube-reserved=cpu=250m,memory=256Mi",
      "system-reserved=cpu=250m,memory=256Mi",
      "eviction-hard=memory.available<512Mi,nodefs.available<10%,imagefs.available<15%,nodefs.inodesFree<5%,imagefs.inodesFree<5%",
    ]
    error_message = "The canary selector must preserve every kubelet reservation and hard eviction threshold."
  }

  assert {
    condition = (
      rancher2_cluster_v2.this.rke_config[0].machine_selector_config[0].machine_label_selector[0].match_expressions[0].key == "rke.cattle.io/node-name" &&
      rancher2_cluster_v2.this.rke_config[0].machine_selector_config[0].machine_label_selector[0].match_expressions[0].operator == "In" &&
      length(rancher2_cluster_v2.this.rke_config[0].machine_selector_config[0].machine_label_selector[0].match_expressions[0].values) == 1 &&
      rancher2_cluster_v2.this.rke_config[0].machine_selector_config[0].machine_label_selector[0].match_expressions[0].values[0] == "staging-server-1"
    )
    error_message = "The canary selector must target exactly the requested Rancher node names."
  }
}

run "configures_cluster_agent_memory_request" {
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
      cluster_name                 = "staging"
      ssh_key_name                 = "k3s-rancher-admin"
      cluster_agent_memory_request = "1Gi"
    }
    hcloud_token = "test-token"
  }

  override_resource {
    target = rancher2_cluster_v2.this
    values = {
      cluster_registration_token = [{
        annotations                   = {}
        cluster_id                    = "fleet-default/staging"
        command                       = ""
        id                            = "token-id"
        insecure_command              = ""
        insecure_node_command         = ""
        insecure_windows_node_command = ""
        labels                        = {}
        manifest_url                  = ""
        name                          = "staging-token"
        node_command                  = "curl -fsSL https://rancher.example.com/system-agent-install.sh | sh -s -"
        token                         = "registration-token"
        windows_node_command          = ""
      }]
    }
  }

  assert {
    condition = (
      rancher2_cluster_v2.this.cluster_agent_deployment_customization[0].override_resource_requirements[0].memory_request == "1Gi" &&
      rancher2_cluster_v2.this.cluster_agent_deployment_customization[0].override_resource_requirements[0].memory_limit == null
    )
    error_message = "The cluster-agent customization must set only the requested memory without imposing a limit."
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

run "rejects_invalid_kubelet_reservations" {
  command = plan

  variables {
    config = {
      cluster_name                   = "production"
      ssh_key_name                   = "k3s-rancher-admin"
      kube_reserved_cpu              = "250"
      kube_reserved_memory           = "256Mi"
      system_reserved_cpu            = "250m"
      system_reserved_memory         = "256Mi"
      eviction_hard_memory_available = "512Mi"
    }
    hcloud_token = "test-token"
  }

  expect_failures = [var.config]
}
run "rejects_partial_kubelet_reservations" {
  command = plan

  variables {
    config = {
      cluster_name         = "production"
      ssh_key_name         = "k3s-rancher-admin"
      kube_reserved_cpu    = "250m"
      kube_reserved_memory = "256Mi"
    }
    hcloud_token = "test-token"
  }

  expect_failures = [var.config]
}

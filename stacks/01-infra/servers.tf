locals {
  sysctl_config = <<-EOT
    # Rancher and busy kubelets exhaust the defaults quickly.
    fs.inotify.max_user_instances = 8192
    fs.inotify.max_user_watches   = 524288
    vm.max_map_count              = 262144
    net.ipv4.ip_forward           = 1
  EOT

  bootstrap_script = file("${path.module}/templates/k3s-bootstrap.sh")

  server_user_data = [
    for i in range(var.server_count) : templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
      hostname         = "${var.cluster_name}-server-${i + 1}"
      k3s_config       = local.k3s_server_configs[i]
      sysctl_config    = local.sysctl_config
      bootstrap_script = local.bootstrap_script
      manifests        = local.server_manifests
      bootstrap_env = join("\n", [
        "NODE_IP=\"${local.server_private_ips[i]}\"",
        "K3S_VERSION=\"${var.k3s_version}\"",
        # Node 0 bootstraps etcd and waits for nobody. Every later node waits
        # for all earlier ones AND for the load balancer itself, because that is
        # the address it will actually join through - the LB needs ~30s of
        # passing health checks before it forwards anything.
        "WAIT_FOR_PEERS=\"${join(" ", i == 0 ? [] : concat(slice(local.server_private_ips, 0, i), [local.lb_private_ip]))}\"",
        "JOIN_DELAY=\"${i * 15}\"",
        "",
      ])
    })
  ]
}

resource "hcloud_server" "server" {
  count = var.server_count

  name               = "${var.cluster_name}-server-${count.index + 1}"
  server_type        = var.server_type
  image              = var.os_image
  location           = var.location
  ssh_keys           = [hcloud_ssh_key.this.id]
  placement_group_id = hcloud_placement_group.servers.id
  user_data          = local.server_user_data[count.index]

  labels = local.common_labels

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  # Attach the private network as part of creating the server, NOT afterwards
  # with a separate hcloud_server_network resource.
  #
  # A later attach is a hot-plug: the NIC appears after cloud-init has already
  # run its network stage, so nothing configures it and it sits there DOWN with
  # no address. The bootstrap script then waits for an IP that never arrives.
  # Attaching here means the interface exists before the OS boots.
  network {
    network_id = hcloud_network.this.id
    ip         = local.server_private_ips[count.index]
  }

  lifecycle {
    # cloud-init only ever runs on the FIRST boot. Once a node is up, editing
    # user_data changes nothing on that node - but Terraform would still want to
    # destroy and recreate it, which for count.index 0..2 means wiping the whole
    # control plane in one apply. Roll nodes deliberately instead:
    #   terraform apply -replace='hcloud_server.server[2]'
    ignore_changes = [user_data, ssh_keys, image]
  }

  depends_on = [
    # The Hetzner API cannot reference a subnet from a server, so Terraform
    # would otherwise create both in parallel and the attach above could land
    # before the subnet exists.
    hcloud_network_subnet.nodes,
    hcloud_load_balancer_service.api,
    # The firewall attaches by label selector, so it has no implicit dependency
    # on these servers. Ordering it first means no node ever boots with an
    # unfiltered public interface.
    hcloud_firewall_attachment.nodes,
  ]
}

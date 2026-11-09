data "hcloud_server_type" "worker" {
  count = var.config.dev || var.config.worker_count == 0 || !var.config.worker_auto_location ? 0 : 1

  name = var.config.worker_type
}

resource "hcloud_server" "node" {
  for_each = local.nodes

  name               = each.value.name
  server_type        = each.value.server_type
  image              = data.hcloud_image.os.name
  location           = each.value.location
  ssh_keys           = [data.hcloud_ssh_key.admin.id]
  placement_group_id = var.config.dev ? null : (startswith(each.key, "server-") ? hcloud_placement_group.nodes[0].id : null)
  user_data          = sensitive(local.node_user_data[each.key])

  labels = merge(local.common_labels, {
    node_class = startswith(each.key, "server-") ? "server" : "worker"
  })

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  dynamic "network" {
    for_each = [each.value.private_ip]

    content {
      network_id = hcloud_network.this[0].id
      ip         = network.value
    }
  }

  lifecycle {
    # Registration commands and cloud-init run only on first boot. Token refreshes
    # must not replace every etcd member. Replace nodes deliberately, one at a time.
    ignore_changes = [user_data, ssh_keys, image]

    precondition {
      condition = var.config.dev || !startswith(each.key, "worker-") || !var.config.worker_auto_location || (
        length(data.hcloud_server_type.worker[0].locations) > 0 &&
        alltrue([
          for location in data.hcloud_server_type.worker[0].locations :
          lookup(local.network_zones, location.name, null) == local.network_zones[var.config.location]
        ])
      )
      error_message = "Automatic worker placement requires a server type whose every supported location is in the cluster network zone; choose a worker type confined to this zone."
    }
  }

  depends_on = [
    hcloud_network_subnet.nodes,
    hcloud_firewall_attachment.nodes,
    hcloud_load_balancer_service.kubernetes_api,
    hcloud_load_balancer_service.rke2_supervisor,
  ]
}

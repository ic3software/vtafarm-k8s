resource "hcloud_primary_ip" "dev_api" {
  count = var.config.dev ? 1 : 0

  name        = "${var.config.cluster_name}-api"
  type        = "ipv4"
  location    = var.config.location
  auto_delete = false
  labels      = local.common_labels
}

data "hcloud_server_type" "auto_location" {
  for_each = toset([
    for node in values(local.nodes) : node.server_type
    if !var.config.dev && node.auto_location
  ])

  name = each.value
}

resource "hcloud_server" "node" {
  for_each = local.nodes

  name               = each.value.name
  server_type        = each.value.server_type
  image              = data.hcloud_image.os.name
  location           = each.value.location
  ssh_keys           = [data.hcloud_ssh_key.admin.id]
  placement_group_id = var.config.dev ? null : (each.value.node_class == "control-plane" ? hcloud_placement_group.nodes[0].id : null)
  user_data          = sensitive(local.node_user_data[each.key])

  labels = merge(local.common_labels, {
    node_class = each.value.node_class
    node_pool  = each.value.pool
  })

  public_net {
    ipv4_enabled = true
    ipv4         = var.config.dev && each.key == local.dev_server_key ? hcloud_primary_ip.dev_api[0].id : null
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.this[0].id
    ip         = each.value.requested_private_ip
  }

  lifecycle {
    # Registration commands and cloud-init run only on first boot. Token refreshes
    # must not replace every etcd member. Replace nodes deliberately, one at a time.
    ignore_changes = [user_data, ssh_keys, image]

    precondition {
      condition = var.config.dev || !each.value.auto_location || (
        length(data.hcloud_server_type.auto_location[each.value.server_type].locations) > 0 &&
        alltrue([
          for location in data.hcloud_server_type.auto_location[each.value.server_type].locations :
          lookup(local.network_zones, location.name, null) == local.network_zones[var.config.location]
        ])
      )
      error_message = "Automatic placement requires a server type whose every supported location is in the cluster network zone; choose a type confined to this zone."
    }
  }

  depends_on = [
    hcloud_network_subnet.nodes,
    hcloud_firewall_attachment.nodes,
    hcloud_load_balancer_service.kubernetes_api,
    hcloud_load_balancer_service.rke2_supervisor,
  ]
}

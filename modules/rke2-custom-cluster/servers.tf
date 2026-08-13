resource "hcloud_server" "node" {
  for_each = local.nodes

  name               = each.value.name
  server_type        = each.value.server_type
  image              = data.hcloud_image.os.name
  location           = var.config.location
  ssh_keys           = [data.hcloud_ssh_key.admin.id]
  placement_group_id = startswith(each.key, "server-") ? hcloud_placement_group.nodes.id : null
  user_data          = sensitive(local.node_user_data[each.key])

  labels = merge(local.common_labels, {
    node_class = startswith(each.key, "server-") ? "server" : "worker"
  })

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.this.id
    ip         = each.value.private_ip
  }

  lifecycle {
    # Registration commands and cloud-init run only on first boot. Token refreshes
    # must not replace every etcd member. Replace nodes deliberately, one at a time.
    ignore_changes = [user_data, ssh_keys, image]
  }

  depends_on = [
    hcloud_network_subnet.nodes,
    hcloud_firewall_attachment.nodes,
    hcloud_load_balancer_service.kubernetes_api,
    hcloud_load_balancer_service.rke2_supervisor,
  ]
}

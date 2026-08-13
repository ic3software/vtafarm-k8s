resource "hcloud_load_balancer" "api" {
  name               = "${var.config.cluster_name}-api"
  load_balancer_type = var.config.load_balancer_type
  location           = var.config.location

  algorithm {
    type = "round_robin"
  }

  labels = local.common_labels
}

resource "hcloud_load_balancer_network" "api" {
  load_balancer_id = hcloud_load_balancer.api.id
  subnet_id        = hcloud_network_subnet.nodes.id
  ip               = local.lb_private_ip
}

resource "hcloud_load_balancer_target" "servers" {
  for_each = local.server_nodes

  type             = "server"
  load_balancer_id = hcloud_load_balancer.api.id
  server_id        = hcloud_server.node[each.key].id
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.api]
}

resource "hcloud_load_balancer_service" "kubernetes_api" {
  load_balancer_id = hcloud_load_balancer.api.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443

  health_check {
    protocol = "tcp"
    port     = 6443
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

resource "hcloud_load_balancer_service" "rke2_supervisor" {
  load_balancer_id = hcloud_load_balancer.api.id
  protocol         = "tcp"
  listen_port      = 9345
  destination_port = 9345

  health_check {
    protocol = "tcp"
    port     = 9345
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

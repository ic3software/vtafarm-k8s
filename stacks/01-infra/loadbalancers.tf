# ---------------------------------------------------------------------------
# One load balancer, three services.
#
# :6443 is the "fixed registration address" from the k3s HA docs - servers 2..n
# join through it, and it is the endpoint baked into your kubeconfig. Because it
# is stable, a server node can be replaced without touching anything else.
#
# :80 and :443 reach Traefik, which runs as a DaemonSet bound to those host
# ports on every node. Both are plain TCP: TLS is terminated by Traefik, not the
# load balancer, because cert-manager owns the Let's Encrypt certificates.
#
# Targets belong to the load balancer while health checks belong to each
# service, so every service checks every target. Every node here is a server
# running both the API server and Traefik, so all three services report green.
# ---------------------------------------------------------------------------
resource "hcloud_load_balancer" "this" {
  name               = var.cluster_name
  load_balancer_type = var.load_balancer_type
  location           = var.location
  algorithm { type = "round_robin" }
  labels = local.common_labels
}

resource "hcloud_load_balancer_network" "this" {
  load_balancer_id = hcloud_load_balancer.this.id
  subnet_id        = hcloud_network_subnet.nodes.id
  ip               = local.lb_private_ip
}

resource "hcloud_load_balancer_target" "nodes" {
  type             = "label_selector"
  load_balancer_id = hcloud_load_balancer.this.id
  label_selector   = "cluster=${var.cluster_name}"
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.this]
}

resource "hcloud_load_balancer_service" "api" {
  load_balancer_id = hcloud_load_balancer.this.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443

  # No PROXY protocol here - the k3s API server does not speak it.

  health_check {
    protocol = "tcp"
    port     = 6443
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

resource "hcloud_load_balancer_service" "http" {
  load_balancer_id = hcloud_load_balancer.this.id
  protocol         = "tcp"
  listen_port      = 80
  destination_port = 80
  proxyprotocol    = var.enable_proxy_protocol

  health_check {
    protocol = "tcp"
    port     = 80
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

resource "hcloud_load_balancer_service" "https" {
  load_balancer_id = hcloud_load_balancer.this.id
  protocol         = "tcp"
  listen_port      = 443
  destination_port = 443
  proxyprotocol    = var.enable_proxy_protocol

  health_check {
    protocol = "tcp"
    port     = 443
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

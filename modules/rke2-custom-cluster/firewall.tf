# Hetzner Cloud Firewalls filter public interfaces only. Normal clusters keep
# node traffic private; dev runs every RKE2 component locally on its sole node.
resource "hcloud_firewall" "nodes" {
  name   = "${var.config.cluster_name}-nodes"
  labels = local.common_labels

  rule {
    description = "SSH"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.config.ssh_allowed_cidrs
  }

  dynamic "rule" {
    for_each = var.config.dev ? [1] : []

    content {
      description = "Kubernetes API"
      direction   = "in"
      protocol    = "tcp"
      port        = "6443"
      source_ips  = var.config.ssh_allowed_cidrs
    }
  }

  dynamic "rule" {
    for_each = var.config.dev ? [1] : []

    content {
      description = "HTTP ingress"
      direction   = "in"
      protocol    = "tcp"
      port        = "80"
      source_ips  = ["0.0.0.0/0"]
    }
  }

  dynamic "rule" {
    for_each = var.config.dev ? [1] : []

    content {
      description = "HTTPS ingress"
      direction   = "in"
      protocol    = "tcp"
      port        = "443"
      source_ips  = ["0.0.0.0/0"]
    }
  }

  rule {
    description = "ICMP (ping and path MTU discovery)"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0"]
  }
}

resource "hcloud_firewall_attachment" "nodes" {
  firewall_id = hcloud_firewall.nodes.id

  label_selectors = ["cluster=${var.config.cluster_name},distro=rke2"]
}

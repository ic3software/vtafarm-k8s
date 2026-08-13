# Hetzner Cloud Firewalls filter public interfaces only. RKE2, etcd, the CNI,
# and kubelet communicate on the private network and are not exposed here.
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

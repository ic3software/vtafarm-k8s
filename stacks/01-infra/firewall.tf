# Hetzner Cloud firewalls only filter the PUBLIC interface. Traffic inside the
# private network (etcd 2379-2380, API 6443, flannel VXLAN 8472, kubelet 10250)
# is never touched by them, which is why every k3s port is bound to the private
# IP and nothing cluster-internal has to be opened here.
resource "hcloud_firewall" "nodes" {
  name   = "${var.cluster_name}-nodes"
  labels = local.common_labels

  rule {
    description = "SSH"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.ssh_allowed_cidrs
  }

  rule {
    description = "ICMP (ping / path MTU discovery)"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0"]
  }
}

resource "hcloud_firewall_attachment" "nodes" {
  firewall_id = hcloud_firewall.nodes.id

  label_selectors = ["cluster=${var.cluster_name}"]
}

# The shared secret every node uses to join the cluster. k3s also derives the
# key that encrypts confidential data inside etcd from it, so losing this token
# means a snapshot can no longer be restored. It lives in the OpenTofu state
# and is exposed via `tofu output -raw k3s_token`.
resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

resource "hcloud_network" "this" {
  name     = var.cluster_name
  ip_range = var.network_cidr
  labels   = local.common_labels
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.this.id
  type         = "cloud"
  network_zone = local.network_zone
  ip_range     = var.subnet_cidr
}

# OpenTofu owns this key. Hetzner rejects a second key with the same
# fingerprint, so if the public key is already in the project by hand, delete it
# there first.
resource "hcloud_ssh_key" "this" {
  name       = "${var.cluster_name}-admin"
  public_key = file(pathexpand(var.ssh_public_key_path))
  labels     = local.common_labels
}


# "spread" asks Hetzner to place these servers on different physical hosts.
# Without it three "HA" control-plane nodes can end up on one machine and a
# single hardware failure takes out etcd quorum.
resource "hcloud_placement_group" "servers" {
  name   = "${var.cluster_name}-servers"
  type   = "spread"
  labels = local.common_labels
}


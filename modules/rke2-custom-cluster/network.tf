resource "hcloud_network" "this" {
  name     = var.config.cluster_name
  ip_range = var.config.network_cidr
  labels   = local.common_labels
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.this.id
  type         = "cloud"
  network_zone = local.network_zones[var.config.location]
  ip_range     = var.config.subnet_cidr
}

data "hcloud_ssh_key" "admin" {
  name = var.config.ssh_key_name
}

data "hcloud_image" "os" {
  name              = var.config.os_image
  with_architecture = "x86"
}

resource "hcloud_placement_group" "nodes" {
  name   = "${var.config.cluster_name}-servers"
  type   = "spread"
  labels = local.common_labels
}

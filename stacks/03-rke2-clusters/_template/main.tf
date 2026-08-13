module "rke2" {
  source = "../../../modules/rke2-custom-cluster"

  # The directory name is the source of truth for the Rancher cluster name.
  # Defaults match stack 01; var.cluster only contains user overrides.
  config = merge(
    {
      ssh_key_name = "k3s-rancher-admin"
    },
    var.cluster,
    {
      cluster_name = basename(abspath(path.root))
    },
  )

  hcloud_token = var.hcloud_token
}

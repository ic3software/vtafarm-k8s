# Terraform has no native "copy a file off a host" primitive, so the kubeconfig
# is pulled with a small script. It also doubles as the readiness gate: the
# apply does not finish until the first server reports a completed bootstrap.
resource "null_resource" "kubeconfig" {
  triggers = {
    server_id    = hcloud_server.server[0].id
    api_endpoint = local.kube_api_endpoint
    out_path     = var.kubeconfig_path
  }

  provisioner "local-exec" {
    command = join(" ", [
      "bash",
      "${path.module}/../../scripts/fetch-kubeconfig.sh",
      hcloud_server.server[0].ipv4_address,
      pathexpand(var.ssh_private_key_path),
      local.kube_api_endpoint,
      var.kubeconfig_path,
      var.cluster_name,
    ])
  }

  depends_on = [
    hcloud_server.server,
    hcloud_load_balancer_target.nodes,
  ]
}

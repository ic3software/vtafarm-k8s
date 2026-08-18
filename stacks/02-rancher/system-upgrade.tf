# ---------------------------------------------------------------------------
# rancher/system-upgrade-controller
#
# Upgrading k3s means replacing a binary and restarting a systemd unit on every
# node, in the right order. The controller does that from inside the cluster:
# you declare the desired version in a Plan, it cordons one node at a time,
# swaps the binary, waits for the node to come back, then moves on.
#
# Installed with kubectl because upstream ships plain YAML, not a chart.
# ---------------------------------------------------------------------------

locals {
  suc_base = "https://github.com/rancher/system-upgrade-controller/releases/download/${var.system_upgrade_controller_version}"

  # Pinned to an exact version on purpose. A channel URL would work here too,
  # but it would happily upgrade the cluster past what the installed Rancher
  # chart accepts, unattended.
  server_plan = yamlencode({
    apiVersion = "upgrade.cattle.io/v1"
    kind       = "Plan"
    metadata = {
      name      = "server-plan"
      namespace = "system-upgrade"
    }
    spec = {
      version = var.k3s_target_version

      # One node at a time, so etcd never loses quorum.
      concurrency        = 1
      cordon             = true
      serviceAccountName = "system-upgrade"
      nodeSelector = {
        matchExpressions = [{
          key      = "node-role.kubernetes.io/control-plane"
          operator = "In"
          values   = ["true"]
        }]
      }
      upgrade = { image = "rancher/k3s-upgrade" }
    }
  })
}

resource "null_resource" "system_upgrade_controller" {
  triggers = {
    version    = var.system_upgrade_controller_version
    kubeconfig = pathexpand(var.kubeconfig_path)
  }

  provisioner "local-exec" {
    environment = { KUBECONFIG = pathexpand(var.kubeconfig_path) }
    interpreter = ["bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      kubectl apply -f "${local.suc_base}/crd.yaml"
      kubectl apply -f "${local.suc_base}/system-upgrade-controller.yaml"
      kubectl -n system-upgrade rollout status deploy/system-upgrade-controller --timeout=300s
    EOT
  }
}

resource "null_resource" "k3s_upgrade_plan" {
  triggers = {
    plan       = local.server_plan
    kubeconfig = pathexpand(var.kubeconfig_path)
  }

  provisioner "local-exec" {
    environment = { KUBECONFIG = pathexpand(var.kubeconfig_path) }
    interpreter = ["bash", "-c"]
    command     = "kubectl apply -f - <<'PLANEOF'\n${local.server_plan}\nPLANEOF"
  }

  provisioner "local-exec" {
    when        = destroy
    environment = { KUBECONFIG = self.triggers.kubeconfig }
    interpreter = ["bash", "-c"]
    command     = "kubectl -n system-upgrade delete plan server-plan --ignore-not-found"
    on_failure  = continue
  }

  depends_on = [null_resource.system_upgrade_controller]
}

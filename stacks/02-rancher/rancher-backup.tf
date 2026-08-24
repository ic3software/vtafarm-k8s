resource "kubernetes_namespace" "cattle_resources_system" {
  metadata {
    name = "cattle-resources-system"
  }
}

resource "kubernetes_secret" "backup_s3" {
  metadata {
    name      = "s3-backup-credentials"
    namespace = kubernetes_namespace.cattle_resources_system.metadata[0].name
  }

  # These key names are fixed by the rancher-backup operator.
  data = {
    accessKey = var.backup_s3_access_key
    secretKey = var.backup_s3_secret_key
  }

  type = "Opaque"
}

resource "helm_release" "rancher_backup_crd" {
  name       = "rancher-backup-crd"
  repository = "https://charts.rancher.io"
  chart      = "rancher-backup-crd"
  version    = var.rancher_backup_chart_version
  namespace  = kubernetes_namespace.cattle_resources_system.metadata[0].name

  wait    = true
  timeout = 300

  depends_on = [helm_release.rancher]
}

resource "helm_release" "rancher_backup" {
  name       = "rancher-backup"
  repository = "https://charts.rancher.io"
  chart      = "rancher-backup"
  version    = var.rancher_backup_chart_version
  namespace  = kubernetes_namespace.cattle_resources_system.metadata[0].name

  set = [
    {
      name  = "s3.enabled"
      value = "true"
    },
    {
      name  = "s3.credentialSecretName"
      value = kubernetes_secret.backup_s3.metadata[0].name
    },
    {
      name  = "s3.credentialSecretNamespace"
      value = kubernetes_namespace.cattle_resources_system.metadata[0].name
    },
    {
      name  = "s3.bucketName"
      value = var.backup_s3_bucket
    },
    {
      name  = "s3.folder"
      value = var.backup_s3_folder
    },
    {
      name  = "s3.region"
      value = var.backup_s3_region
    },
    {
      name  = "s3.endpoint"
      value = var.backup_s3_endpoint
    },
  ]

  wait    = true
  timeout = 600

  depends_on = [helm_release.rancher_backup_crd]
}

locals {
  rancher_backup_manifest = yamlencode({
    apiVersion = "resources.cattle.io/v1"
    kind       = "Backup"
    metadata = {
      name = "rancher-scheduled-backup"
    }
    spec = {
      resourceSetName = "rancher-resource-set-full"
      schedule        = var.rancher_backup_schedule
      retentionCount  = var.rancher_backup_retention
    }
  })
}

# The Backup custom resource itself. It is applied with kubectl rather than a
# kubernetes_manifest resource because its CRD is installed in this same apply,
# and kubernetes_manifest needs the CRD to already exist at PLAN time.
resource "null_resource" "rancher_backup_schedule" {
  triggers = {
    manifest   = local.rancher_backup_manifest
    kubeconfig = pathexpand(var.kubeconfig_path)
  }

  provisioner "local-exec" {
    environment = { KUBECONFIG = pathexpand(var.kubeconfig_path) }
    command     = "kubectl apply -f - <<'EOF'\n${local.rancher_backup_manifest}\nEOF"
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    when        = destroy
    environment = { KUBECONFIG = self.triggers.kubeconfig }
    command     = "kubectl delete backup rancher-scheduled-backup --ignore-not-found"
    interpreter = ["bash", "-c"]
    on_failure  = continue
  }

  depends_on = [helm_release.rancher_backup]
}

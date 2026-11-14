provider "helm" {
  kubernetes = {
    config_path = pathexpand(local.kubeconfig_path)
  }
}

provider "kubernetes" {
  config_path = pathexpand(local.kubeconfig_path)
}

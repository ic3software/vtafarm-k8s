# Both providers read the kubeconfig stack 03 wrote for this cluster. Splitting
# the platform into its own stack is what makes that safe: the RKE2 cluster
# already exists and is Active by the time these providers are configured, so
# there is no chicken-and-egg between "create the cluster" and "talk to it" -
# the same reason stack 02 is separate from stack 01.
provider "helm" {
  kubernetes = {
    config_path = pathexpand(local.kubeconfig_path)
  }
}

provider "kubernetes" {
  config_path = pathexpand(local.kubeconfig_path)
}

resource "kubernetes_priority_class_v1" "vault_transit" {
  metadata {
    name = "vtafarm-vault-transit"
  }

  value             = 2000
  global_default    = false
  preemption_policy = "Never"

  description = "Transit Vault; scheduled ahead of the farm Vault and ordinary workloads."
}

resource "kubernetes_priority_class_v1" "vault" {
  metadata {
    name = "vtafarm-vault"
  }

  value             = 1000
  global_default    = false
  preemption_policy = "Never"

  description = "Farm Vault; scheduled ahead of ordinary workloads."
}

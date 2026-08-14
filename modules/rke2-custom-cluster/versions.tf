terraform {
  required_version = ">= 1.6.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.68.0, < 2.0.0"
    }
    rancher2 = {
      source  = "rancher/rancher2"
      version = ">= 14.1.1, < 15.0.0"
    }
  }
}

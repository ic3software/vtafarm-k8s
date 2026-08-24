terraform {
  required_version = ">= 1.12.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.68"
    }
    rancher2 = {
      source  = "rancher/rancher2"
      version = "~> 14.1"
    }
  }
}

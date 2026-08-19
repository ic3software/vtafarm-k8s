locals {
  network_zones = {
    fsn1 = "eu-central"
    nbg1 = "eu-central"
    hel1 = "eu-central"
    ash  = "us-east"
    hil  = "us-west"
    sin  = "ap-southeast"
  }

  common_labels = {
    cluster = var.config.cluster_name
    managed = "opentofu"
    distro  = "rke2"
  }

  lb_private_ip = cidrhost(var.config.subnet_cidr, 10)

  # The kernel names Hetzner's private NIC after the server type (enp7s0, ens10,
  # ...), so the bootstrap renames it to something stable that the cluster-wide
  # canal manifest below can name on every machine.
  private_interface = "rke2-private"

  # Hetzner private networks run at MTU 1450.
  private_interface_mtu = 1450

  server_nodes = {
    for i in range(var.config.server_count) : "server-${i + 1}" => {
      name        = "${var.config.cluster_name}-server-${i + 1}"
      private_ip  = cidrhost(var.config.subnet_cidr, 101 + i)
      server_type = var.config.server_type
      roles = concat(
        ["etcd", "controlplane"],
        var.config.servers_are_workers ? ["worker"] : [],
      )
    }
  }

  worker_nodes = {
    for i in range(var.config.worker_count) : "worker-${i + 1}" => {
      name        = "${var.config.cluster_name}-worker-${i + 1}"
      private_ip  = cidrhost(var.config.subnet_cidr, 151 + i)
      server_type = var.config.worker_type
      roles       = ["worker"]
    }
  }

  nodes = merge(local.server_nodes, local.worker_nodes)

  tls_sans = compact([
    hcloud_load_balancer.api.ipv4,
    local.lb_private_ip,
    var.config.api_hostname,
  ])

  machine_global_config = yamlencode({
    cni                      = var.config.cni
    ingress-controller       = var.config.ingress_controller
    cluster-cidr             = var.config.pod_cidr
    service-cidr             = var.config.service_cidr
    disable-cloud-controller = true
    cloud-provider-name      = "external"
    secrets-encryption       = true
    tls-san                  = local.tls_sans
    write-kubeconfig-mode    = "0600"
  })

  hcloud_secret_manifest = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "hcloud"
      namespace = "kube-system"
    }
    stringData = {
      token   = var.hcloud_token
      network = hcloud_network.this.name
    }
  })

  hcloud_ccm_manifest = yamlencode({
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChart"
    metadata = {
      name      = "hcloud-cloud-controller-manager"
      namespace = "kube-system"
    }
    spec = {
      repo            = "https://charts.hetzner.cloud"
      chart           = "hcloud-cloud-controller-manager"
      version         = var.config.hcloud_ccm_version
      targetNamespace = "kube-system"
      bootstrap       = true
      valuesContent = yamlencode({
        networking = { enabled = false }
        env = {
          HCLOUD_NETWORK = {
            valueFrom = {
              secretKeyRef = {
                name = "hcloud"
                key  = "network"
              }
            }
          }
          HCLOUD_NETWORK_ROUTES_ENABLED = { value = "false" }
        }
      })
    }
  })

  hcloud_csi_manifest = yamlencode({
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChart"
    metadata = {
      name      = "hcloud-csi"
      namespace = "kube-system"
    }
    spec = {
      repo            = "https://charts.hetzner.cloud"
      chart           = "hcloud-csi"
      version         = var.config.hcloud_csi_version
      targetNamespace = "kube-system"
      # The chart claims the default StorageClass. RKE2 reconciles this manifest,
      # so anything that unsets the annotation afterwards loses on the next sync.
      valuesContent = yamlencode({
        storageClasses = [{
          name                = "hcloud-volumes"
          defaultStorageClass = false
          reclaimPolicy       = "Delete"
        }]
      })
    }
  })

  # Left alone, canal binds flannel to the default-route interface — the public
  # NIC, where hcloud_firewall.nodes drops VXLAN and cross-node pod traffic with
  # it. RKE2 has no k3s-style flannel-iface flag, so the chart is the only place
  # to say this. vethuMTU has to follow: it is not derived from the interface,
  # and pods sending 1450-byte frames into a 1400-byte tunnel would blackhole.
  canal_manifest = yamlencode({
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChartConfig"
    metadata = {
      name      = "rke2-canal"
      namespace = "kube-system"
    }
    spec = {
      valuesContent = yamlencode({
        flannel = { iface = local.private_interface }
        calico  = { vethuMTU = local.private_interface_mtu - 50 }
      })
    }
  })

  additional_manifest = join("\n---\n", concat(
    [
      local.hcloud_secret_manifest,
      local.hcloud_ccm_manifest,
      local.hcloud_csi_manifest,
    ],
    var.config.cni == "canal" ? [local.canal_manifest] : [],
  ))

  # Rancher owns the bundled Traefik's configuration on a cluster it manages, so
  # a HelmChartConfig applied with kubectl is reverted on the next sync. These
  # are the same values, set where Rancher will not fight them.
  #
  # The redirect replaces ingress-nginx's per-Ingress ssl-redirect annotation,
  # which is why the Ingresses vtafarm-api creates carry none.
  chart_values = yamlencode({
    rke2-traefik = {
      ingressClass = {
        isDefaultClass = true
      }
      ports = {
        web = {
          http = {
            redirections = {
              entryPoint = {
                to        = "websecure"
                scheme    = "https"
                permanent = true
              }
            }
          }
        }
        websecure = {
          http = {
            tls = {
              enabled = true
            }
          }
        }
      }
    }
  })

  registration_command = rancher2_cluster_v2.this.cluster_registration_token[0].node_command

  node_user_data = {
    for key, node in local.nodes : key => templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
      hostname              = node.name
      node_private_ip       = node.private_ip
      private_interface     = local.private_interface
      private_interface_mtu = local.private_interface_mtu
      bootstrap_script      = file("${path.module}/templates/rancher-node-bootstrap.sh")
      registration_script = join(" ", concat(
        [local.registration_command],
        [for role in node.roles : "--${role}"],
        ["--internal-address", node.private_ip, "--node-name", node.name],
      ))
    })
  }
}

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

  # Hetzner private networks run at MTU 1450.
  private_interface_mtu   = 1450
  private_network_gateway = cidrhost(var.config.network_cidr, 1)

  # The kernel names Hetzner's private NIC after the server type (enp7s0, ens10,
  # ...), so canal is pointed at it by address instead. Every address this module
  # hands out sits in the first /24 of the subnet.
  private_subnet_regex = "^${replace(regex("^\\d+\\.\\d+\\.\\d+", cidrhost(var.config.subnet_cidr, 0)), ".", "\\.")}\\."

  server_nodes = {
    for i in range(var.config.dev ? 1 : var.config.server_count) : "server-${i + 1}" => {
      name        = "${var.config.cluster_name}-server-${i + 1}"
      private_ip  = cidrhost(var.config.subnet_cidr, 101 + i)
      server_type = var.config.server_type
      location    = var.config.location
      roles = concat(
        ["etcd", "controlplane"],
        var.config.dev || var.config.servers_are_workers ? ["worker"] : [],
      )
    }
  }

  worker_nodes = {
    for i in range(var.config.worker_count) : "worker-${i + 1}" => {
      name        = "${var.config.cluster_name}-worker-${i + 1}"
      private_ip  = cidrhost(var.config.subnet_cidr, 151 + i)
      server_type = var.config.worker_type
      # Dev workers share the server's location to keep its test topology
      # predictable. Automatic placement is reserved for normal HA clusters.
      location = var.config.dev ? var.config.location : (
        var.config.worker_auto_location ? null : var.config.location
      )
      roles = ["worker"]
    }
  }

  nodes = merge(local.server_nodes, local.worker_nodes)

  tls_sans = var.config.dev ? compact([
    var.config.api_hostname,
    ]) : compact([
    hcloud_load_balancer.api[0].ipv4,
    local.lb_private_ip,
    var.config.api_hostname,
  ])

  kubelet_args = var.config.kube_reserved_cpu == null ? [] : [
    "kube-reserved=cpu=${var.config.kube_reserved_cpu},memory=${var.config.kube_reserved_memory}",
    "system-reserved=cpu=${var.config.system_reserved_cpu},memory=${var.config.system_reserved_memory}",
    join(",", [
      "eviction-hard=memory.available<${var.config.eviction_hard_memory_available}",
      "nodefs.available<10%",
      "imagefs.available<15%",
      "nodefs.inodesFree<5%",
      "imagefs.inodesFree<5%",
    ]),
  ]

  kubelet_reservations_scoped = var.config.kubelet_reservation_node_names != null

  machine_global_config = yamlencode(merge({
    cni                      = var.config.cni
    ingress-controller       = var.config.ingress_controller
    cluster-cidr             = var.config.pod_cidr
    service-cidr             = var.config.service_cidr
    disable-cloud-controller = true
    cloud-provider-name      = "external"
    secrets-encryption       = true
    tls-san                  = local.tls_sans
    },
    # Existing dev servers keep their etcd peer on the public IP after a private
    # NIC is attached. Prefer the matching kubelet certificate address without
    # changing node-ip, which would also migrate the embedded etcd member.
    var.config.dev ? {
      "kube-apiserver-arg" = ["kubelet-preferred-address-types=ExternalIP,InternalIP,Hostname"]
    } : {},
    length(local.kubelet_args) == 0 || local.kubelet_reservations_scoped ? {} : { "kubelet-arg" = local.kubelet_args },
  ))

  hcloud_secret_manifest = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "hcloud"
      namespace = "kube-system"
    }
    stringData = {
      token   = var.hcloud_token
      network = hcloud_network.this[0].name
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
          # Network attachment is already guaranteed by hcloud_server.node.
          # Skipping the metadata check prevents a bad link-local DHCP route
          # from leaving the CCM crash-looping and every node uninitialized.
          HCLOUD_NETWORK_DISABLE_ATTACHED_CHECK = { value = "true" }
          HCLOUD_NETWORK_ROUTES_ENABLED         = { value = "false" }
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
  # it. RKE2 has no k3s-style per-node flannel-iface flag, so the chart selects
  # the interface cluster-wide, by address. vethuMTU has to follow: it is not
  # derived from the interface, and pods sending 1450-byte frames into a
  # 1400-byte tunnel would blackhole.
  canal_manifest = yamlencode({
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChartConfig"
    metadata = {
      name      = "rke2-canal"
      namespace = "kube-system"
    }
    spec = {
      valuesContent = yamlencode({
        flannel = { regexIface = local.private_subnet_regex }
        calico  = { vethuMTU = local.private_interface_mtu - 50 }
      })
    }
  })

  # Existing dev servers may have registered before their private NIC existed,
  # leaving the kubelet certificate valid only for the public IP. Production
  # keeps certificate verification enabled; dev accepts this for placement
  # testing against the private InternalIP without changing the etcd peer IP.
  metrics_server_manifest = yamlencode({
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChartConfig"
    metadata = {
      name      = "rke2-metrics-server"
      namespace = "kube-system"
    }
    spec = {
      valuesContent = yamlencode({
        args = ["--kubelet-insecure-tls"]
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
    var.config.dev ? [local.metrics_server_manifest] : [],
  ))

  # Rancher owns the bundled Traefik's configuration on a cluster it manages, so
  # a HelmChartConfig applied with kubectl is reverted on the next sync. These
  # are the same values, set where Rancher will not fight them.
  #
  # The redirect replaces ingress-nginx's per-Ingress ssl-redirect annotation,
  # which is why the Ingresses vtafarm-api creates carry none.
  # Dev keeps the Service internal so the CCM cannot provision a cloud load
  # balancer, and publishes the DaemonSet directly through host ports instead.
  chart_values = yamlencode({
    rke2-traefik = merge({
      ingressClass = {
        isDefaultClass = true
      }
      ports = {
        web = merge({
          http = {
            redirections = {
              entryPoint = {
                to        = "websecure"
                scheme    = "https"
                permanent = true
              }
            }
          }
        }, var.config.dev ? { hostPort = 80 } : {})
        websecure = merge({
          http = {
            tls = {
              enabled = true
            }
          }
        }, var.config.dev ? { hostPort = 443 } : {})
      }
      }, jsondecode(var.config.dev ? jsonencode({
        deployment = { kind = "DaemonSet" }
        service    = { spec = { type = "ClusterIP" } }
    }) : "{}"))
  })

  registration_command = rancher2_cluster_v2.this.cluster_registration_token[0].node_command

  node_user_data = {
    for key, node in local.nodes : key => templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
      hostname                = node.name
      use_private_network     = true
      node_private_ip         = node.private_ip
      private_network_cidr    = var.config.network_cidr
      private_network_gateway = local.private_network_gateway
      private_interface_mtu   = local.private_interface_mtu
      private_supervisor_url = var.config.dev && startswith(key, "worker-") ? (
        "https://${local.server_nodes["server-1"].private_ip}:9345"
      ) : ""
      bootstrap_script = file("${path.module}/templates/rancher-node-bootstrap.sh")
      registration_script = join(" ", concat(
        [local.registration_command],
        [for role in node.roles : "--${role}"],
        ["--internal-address", node.private_ip],
        ["--node-name", node.name],
      ))
    })
  }
}

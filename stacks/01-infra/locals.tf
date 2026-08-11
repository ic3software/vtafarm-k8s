locals {
  # ---------------------------------------------------------------------------
  # Deterministic private addressing.
  # Fixing the IPs up-front means cloud-init can reference the load balancer and
  # the peer servers without Terraform having to create them first, which is what
  # would otherwise produce a dependency cycle.
  # ---------------------------------------------------------------------------
  lb_private_ip      = cidrhost(var.subnet_cidr, 10)
  server_private_ips = [for i in range(var.server_count) : cidrhost(var.subnet_cidr, 101 + i)]

  # The address every node uses to join. k3s calls this the "fixed registration
  # address"; nodes reach it over the private network.
  registration_address = "https://${local.lb_private_ip}:6443"

  # What your workstation's kubeconfig points at: the same load balancer, but
  # through its public IP.
  kube_api_endpoint = "https://${hcloud_load_balancer.this.ipv4}:6443"

  # A Hetzner network lives in a zone, not a location, and every subnet in it
  # must share that zone. Deriving it from var.location removes a second setting
  # that could silently disagree with the first.
  network_zones = {
    fsn1 = "eu-central"
    nbg1 = "eu-central"
    hel1 = "eu-central"
    ash  = "us-east"
    hil  = "us-west"
    sin  = "ap-southeast"
  }
  network_zone = local.network_zones[var.location]

  common_labels = {
    cluster = var.cluster_name
    managed = "terraform"
  }

  # ---------------------------------------------------------------------------
  # k3s configuration (/etc/rancher/k3s/config.yaml)
  #
  # Built with yamlencode() rather than string templating so quoting/indentation
  # can never go wrong. Keys are exactly the CLI flags without the leading "--".
  # ---------------------------------------------------------------------------

  # Settings that MUST be identical on every server node.
  k3s_common = {
    token = random_password.k3s_token.result

    cluster-cidr = var.cluster_cidr
    service-cidr = var.service_cidr

    # Names/IPs baked into the API server certificate. Without the load balancer
    # address in here, kubectl through it would fail TLS verification.
    tls-san = distinct(concat(
      [hcloud_load_balancer.this.ipv4, local.lb_private_ip],
      var.additional_tls_sans,
    ))

    # Hetzner's cloud controller manager replaces the one bundled with k3s.
    # Disabling k3s' own also removes klipper (servicelb); Traefik is switched to
    # a DaemonSet with hostPorts instead, so the load balancer has a target.
    disable-cloud-controller = true
    disable                  = ["servicelb"]
    kubelet-arg              = ["cloud-provider=external"]

    # Encrypt Secrets at rest in etcd.
    secrets-encryption = true

    write-kubeconfig-mode = "0600"

    etcd-snapshot-schedule-cron = var.etcd_snapshot_schedule_cron
    etcd-snapshot-retention     = var.etcd_snapshot_retention
    etcd-snapshot-compress      = true

    etcd-s3            = true
    etcd-s3-endpoint   = var.etcd_s3_endpoint
    etcd-s3-region     = var.etcd_s3_region
    etcd-s3-bucket     = var.etcd_s3_bucket
    etcd-s3-folder     = coalesce(var.etcd_s3_folder, var.cluster_name)
    etcd-s3-access-key = var.etcd_s3_access_key
    etcd-s3-secret-key = var.etcd_s3_secret_key
    etcd-s3-retention  = var.etcd_s3_retention
  }

  # Per-server config. Index 0 initialises the etcd cluster, the rest join it
  # through the load balancer.
  k3s_server_configs = [
    for i in range(var.server_count) : yamlencode(merge(
      local.k3s_common,
      var.etcd_s3_bucket_lookup_type == "" ? {} : {
        etcd-s3-bucket-lookup-type = var.etcd_s3_bucket_lookup_type
      },
      { node-ip = local.server_private_ips[i] },
      i == 0 ? { cluster-init = true } : { server = local.registration_address },
    ))
  ]

  # ---------------------------------------------------------------------------
  # Auto-deploying manifests (/var/lib/rancher/k3s/server/manifests)
  #
  # k3s applies everything in this directory at startup, before the cluster is
  # otherwise usable. That is exactly what the cloud controller manager needs:
  # until it runs, every node carries the taint
  # node.cloudprovider.kubernetes.io/uninitialized:NoSchedule and nothing else
  # can be scheduled. `bootstrap: true` gives the helm job hostNetwork plus a
  # toleration for that taint, which breaks the chicken-and-egg.
  # ---------------------------------------------------------------------------

  manifest_hcloud_secret = yamlencode({
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

  manifest_hcloud_ccm = yamlencode({
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChart"
    metadata = {
      name      = "hcloud-cloud-controller-manager"
      namespace = "kube-system"
    }
    spec = {
      repo            = "https://charts.hetzner.cloud"
      chart           = "hcloud-cloud-controller-manager"
      version         = var.hcloud_ccm_version
      targetNamespace = "kube-system"
      bootstrap       = true
      valuesContent = yamlencode({
        # Route reconciliation is left off: flannel already tunnels pod traffic
        # over the private network (VXLAN), which needs no Hetzner routes.
        networking = { enabled = false }
        env = {
          # Load balancers are owned by Terraform in this repo. Without this the
          # CCM would create a second, untracked LB for every Service of type
          # LoadBalancer and `terraform destroy` would silently leave it behind.
          HCLOUD_LOAD_BALANCERS_ENABLED = { value = "false" }
        }
      })
    }
  })

  manifest_hcloud_csi = yamlencode({
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChart"
    metadata = {
      name      = "hcloud-csi"
      namespace = "kube-system"
    }
    spec = {
      repo            = "https://charts.hetzner.cloud"
      chart           = "hcloud-csi"
      version         = var.hcloud_csi_version
      targetNamespace = "kube-system"
      valuesContent   = yamlencode({})
    }
  })

  # Traefik ships with k3s. HelmChartConfig merges extra values into the bundled
  # chart instead of replacing it.
  traefik_proxy_ips = var.enable_proxy_protocol ? [var.network_cidr] : []

  traefik_port_values = {
    hostPort         = null # filled per entrypoint below
    proxyProtocol    = { trustedIPs = local.traefik_proxy_ips }
    forwardedHeaders = { trustedIPs = local.traefik_proxy_ips }
  }

  manifest_traefik_config = yamlencode({
    apiVersion = "helm.cattle.io/v1"
    kind       = "HelmChartConfig"
    metadata = {
      name      = "traefik"
      namespace = "kube-system"
    }
    spec = {
      valuesContent = yamlencode({
        # One Traefik per node, bound straight to :80/:443 on the host, so the
        # load balancer can reach it without klipper/servicelb.
        deployment = { kind = "DaemonSet" }
        service    = { enabled = false }
        ports = {
          web       = merge(local.traefik_port_values, { hostPort = 80 })
          websecure = merge(local.traefik_port_values, { hostPort = 443 })
        }
        tolerations = [
          {
            key      = "CriticalAddonsOnly"
            operator = "Exists"
          },
          {
            key      = "node-role.kubernetes.io/control-plane"
            operator = "Exists"
            effect   = "NoSchedule"
          },
          {
            key      = "node-role.kubernetes.io/master"
            operator = "Exists"
            effect   = "NoSchedule"
          },
        ]
      })
    }
  })

  server_manifests = {
    "00-hcloud-secret.yaml"  = local.manifest_hcloud_secret
    "10-hcloud-ccm.yaml"     = local.manifest_hcloud_ccm
    "20-hcloud-csi.yaml"     = local.manifest_hcloud_csi
    "30-traefik-config.yaml" = local.manifest_traefik_config
  }
}

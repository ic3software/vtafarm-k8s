output "kube_api_endpoint" {
  description = "Public Kubernetes API endpoint."
  value       = local.kube_api_endpoint
}

output "load_balancer_ipv4" {
  description = <<-EOT
    Public IPv4 of the load balancer, serving :6443, :80 and :443.
    Point your Rancher DNS A record at this address.
  EOT
  value       = hcloud_load_balancer.this.ipv4
}

output "server_nodes" {
  description = "Cluster nodes: name, public IPv4 and private IPv4."
  value = [
    for i, s in hcloud_server.server : {
      name       = s.name
      public_ip  = s.ipv4_address
      private_ip = local.server_private_ips[i]
    }
  ]
}

output "kubeconfig_path" {
  description = "Where the kubeconfig was written."
  value       = var.kubeconfig_path
}

output "k3s_token" {
  description = <<-EOT
    The k3s join token. It also encrypts confidential data inside etcd, so an
    etcd snapshot is useless without it. Keep a copy somewhere safe:
      tofu output -raw k3s_token
  EOT
  value       = random_password.k3s_token.result
  sensitive   = true
}

output "ssh_command" {
  description = "Shortcut for reaching the first node."
  value       = "ssh root@${hcloud_server.server[0].ipv4_address}"
}

# Left unexpanded: state is shared, so expanding ~ here writes one operator's
# home directory into everybody else's state. Callers expand it themselves.
output "ssh_private_key_path" {
  description = "Private key the helper scripts use to reach the nodes."
  value       = var.ssh_private_key_path
}

output "dns_record_required" {
  description = "DNS record you must create before installing Rancher."
  value       = "<your rancher hostname>  A  ${hcloud_load_balancer.this.ipv4}"
}

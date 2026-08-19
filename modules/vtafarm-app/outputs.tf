output "frontend_url" {
  description = "Where the browser reaches the app."
  value       = "https://${local.frontend_host}"
}

output "api_url" {
  description = "Where the browser reaches the API."
  value       = "https://${local.api_host}"
}

output "dns_records" {
  description = "A records to create, both pointing at the cluster's load balancer."
  value = {
    (local.frontend_host) = var.config.cluster_ingress_ip
    (local.api_host)      = var.config.cluster_ingress_ip
  }
}

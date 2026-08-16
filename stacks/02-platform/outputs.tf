output "rancher_url" {
  description = "Where to log in."
  value       = "https://${var.rancher_hostname}"
}

output "rancher_bootstrap_password" {
  description = <<-EOT
    Password for the initial admin login. Read it with:
      tofu output -raw rancher_bootstrap_password
    Rancher forces you to change it on first login.
  EOT
  value       = local.rancher_bootstrap_password
  sensitive   = true
}

output "letsencrypt_environment" {
  description = "Which ACME endpoint issued the certificate."
  value       = var.letsencrypt_environment
}

output "k3s_target_version" {
  description = "Version the upgrade Plan converges on."
  value       = var.k3s_target_version
}

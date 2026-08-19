output "frontend_url" {
  value = module.app.frontend_url
}

output "api_url" {
  value = module.app.api_url
}

output "dns_records" {
  description = "Create these before applying, or the certificate cannot be issued."
  value       = module.app.dns_records
}

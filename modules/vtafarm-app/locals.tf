locals {
  frontend_host = coalesce(var.config.frontend_host, "vtafarm.${var.config.domain}")
  api_host      = coalesce(var.config.api_host, "vtafarm-api.${var.config.domain}")

  wildcard_secret = "${replace(var.config.domain, ".", "-")}-wildcard-tls"
}

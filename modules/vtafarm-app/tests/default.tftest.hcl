mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "random" {}

run "alertmanager_webhook_secret" {
  command = plan

  variables {
    alertmanager_webhook_token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    config = {
      domain                             = "example.org"
      acme_email                         = "ops@example.org"
      cloudflare_api_token               = "test-cloudflare-token"
      cloudflare_zone_id                 = "test-zone"
      did_hosting_did                    = "did:key:z6Mktest"
      did_hosting_private_key            = "test-private-key"
      farm_did                           = "did:webvh:test:dids.example.org:vtafarm-auth"
      farm_signing_key                   = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
      alertmanager_webhook_enabled        = true
      alertmanager_webhook_token_revision = 1
      vtafarm_version                    = "0.1.0"
      vtafarm_api_version                = "0.1.0"
      cluster_ingress_ip                 = "192.0.2.10"
    }
  }

  assert {
    condition = (
      length(kubernetes_secret_v1.alertmanager_webhook) == 1 &&
      kubernetes_secret_v1.alertmanager_webhook[0].metadata[0].name == "vtafarm-alertmanager-webhook" &&
      kubernetes_secret_v1.alertmanager_webhook[0].metadata[0].namespace == "default" &&
      kubernetes_secret_v1.alertmanager_webhook[0].data_wo_revision == 1
    )
    error_message = "The app stack must create the API-side write-only Alertmanager webhook Secret."
  }

  assert {
    condition = (
      yamldecode(helm_release.api.values[0]).alerting.existingSecret == "vtafarm-alertmanager-webhook" &&
      yamldecode(helm_release.api.values[0]).alerting.tokenRevision == "1"
    )
    error_message = "The API chart must mount the managed webhook Secret and roll when its revision changes."
  }
}

run "alertmanager_webhook_disabled" {
  command = plan

  variables {
    config = {
      domain                  = "example.org"
      acme_email              = "ops@example.org"
      cloudflare_api_token    = "test-cloudflare-token"
      cloudflare_zone_id      = "test-zone"
      did_hosting_did         = "did:key:z6Mktest"
      did_hosting_private_key = "test-private-key"
      farm_did                = "did:webvh:test:dids.example.org:vtafarm-auth"
      farm_signing_key        = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
      vtafarm_version         = "0.1.0"
      vtafarm_api_version     = "0.1.0"
      cluster_ingress_ip      = "192.0.2.10"
    }
  }

  assert {
    condition = (
      length(kubernetes_secret_v1.alertmanager_webhook) == 0 &&
      yamldecode(helm_release.api.values[0]).alerting.existingSecret == ""
    )
    error_message = "Disabling the webhook must omit its Secret and API mount."
  }
}

mock_provider "helm" {}
mock_provider "kubernetes" {}

run "default_topology" {
  command = plan

  variables {
    config = {
      cluster_name = "rke2-vtafarm-production"
    }
  }

  # A sealed Vault reports NOT ready by design, and a fresh install is always
  # sealed. wait = true would hang the apply until timeout and then roll back a
  # Vault that was behaving correctly, so this is load-bearing, not a detail.
  assert {
    condition     = helm_release.vault.wait == false && helm_release.vault_transit.wait == false
    error_message = "Vault releases must not wait for readiness: a freshly installed Vault is sealed and never becomes ready."
  }

  # cert-manager, by contrast, must be fully up before anything asks it for a
  # certificate.
  assert {
    condition     = helm_release.cert_manager.wait == true
    error_message = "cert-manager must be ready before the PKI releases create Certificates."
  }

  assert {
    condition     = length(regexall("retry_join \\{", helm_release.vault.values[0])) == 3
    error_message = "One retry_join stanza per Raft peer, generated from vault_replicas."
  }

  # yamldecode doubles as a syntax check on the rendered template: the
  # conditional storageClass lines and the generated retry_join block are easy
  # to indent wrong, and helm would only complain at install time.
  assert {
    condition = (
      yamldecode(helm_release.vault.values[0]).server.ha.replicas == 3 &&
      yamldecode(helm_release.vault.values[0]).server.dataStorage.storageClass == "longhorn" &&
      yamldecode(helm_release.vault.values[0]).server.auditStorage.storageClass == "longhorn"
    )
    error_message = "The farm Vault must run three peers with both volumes on the longhorn StorageClass."
  }

  assert {
    condition     = yamldecode(helm_release.vault_transit.values[0]).server.dataStorage.storageClass == "longhorn"
    error_message = "The transit Vault's volume must also land on the named StorageClass."
  }

  # The seal stanza is what makes pod restarts unattended. Losing it would only
  # surface on the next restart, as a cluster that never comes back.
  assert {
    condition = (
      strcontains(helm_release.vault.values[0], "seal \"transit\"") &&
      strcontains(helm_release.vault.values[0], "https://vault-transit.vault-transit.svc:8200")
    )
    error_message = "The farm Vault must auto-unseal against the transit Vault's service address."
  }

  assert {
    condition = (
      yamldecode(helm_release.vault_transit.values[0]).server.standalone.enabled == true &&
      !can(yamldecode(helm_release.vault_transit.values[0]).server.ha.raft)
    )
    error_message = "The transit Vault is a single standalone node, not a Raft cluster."
  }

  # It is the root of the unseal chain, so it has no seal stanza of its own.
  assert {
    condition     = !strcontains(helm_release.vault_transit.values[0], "seal \"transit\"")
    error_message = "The transit Vault must not auto-unseal against anything; it is Shamir-sealed by hand."
  }

  # Two default StorageClasses is undefined behaviour: the API server picks one
  # and PVCs silently land on the wrong storage.
  assert {
    condition     = length(kubernetes_annotations.hcloud_volumes_not_default) == 1
    error_message = "Making longhorn the default must demote the hcloud-volumes class."
  }

  assert {
    condition = (
      yamldecode(helm_release.vault_transit_pki.values[0]).networkPolicy.enabled == true &&
      yamldecode(helm_release.vault_transit_pki.values[0]).networkPolicy.allowFromNamespace == "vault"
    )
    error_message = "Only the farm namespace may reach the transit Vault."
  }
}

run "single_node_vault_shrinks_its_raft_peers" {
  command = plan

  variables {
    config = {
      cluster_name   = "rke2-vtafarm-staging"
      vault_replicas = 1
    }
  }

  assert {
    condition     = length(regexall("retry_join \\{", helm_release.vault.values[0])) == 1
    error_message = "retry_join stanzas must follow vault_replicas rather than a hardcoded three."
  }
}

run "longhorn_daily_s3_backup" {
  command = plan

  variables {
    config = {
      cluster_name                  = "rke2-vtafarm-production"
      longhorn_backup_enabled       = true
      longhorn_backup_s3_endpoint   = "https://nbg1.your-objectstorage.com"
      longhorn_backup_s3_region     = "nbg1"
      longhorn_backup_s3_bucket     = "vtafarm-backups"
      longhorn_backup_s3_prefix     = "longhorn/rke2-vtafarm-production"
      longhorn_backup_s3_access_key = "test-access-key"
      longhorn_backup_s3_secret_key = "test-secret-key"
    }
  }

  assert {
    condition = (
      yamldecode(helm_release.longhorn.values[0]).global.timezone == "UTC" &&
      yamldecode(helm_release.longhorn.values[0]).defaultBackupStore.backupTarget == "s3://vtafarm-backups@nbg1/longhorn/rke2-vtafarm-production/" &&
      yamldecode(helm_release.longhorn.values[0]).defaultBackupStore.backupTargetCredentialSecret == "longhorn-backup-s3"
    )
    error_message = "Longhorn must use the configured S3-compatible backup target and credential secret."
  }

  assert {
    condition = (
      yamldecode(helm_release.longhorn.values[0]).extraObjects[0].kind == "RecurringJob" &&
      yamldecode(helm_release.longhorn.values[0]).extraObjects[0].spec.task == "backup" &&
      yamldecode(helm_release.longhorn.values[0]).extraObjects[0].spec.cron == "0 0 * * *" &&
      yamldecode(helm_release.longhorn.values[0]).extraObjects[0].spec.retain == 30 &&
      contains(yamldecode(helm_release.longhorn.values[0]).extraObjects[0].spec.groups, "default")
    )
    error_message = "Longhorn must run a daily midnight UTC backup for the default volume group."
  }

  assert {
    condition = (
      yamldecode(helm_release.longhorn.values[0]).defaultSettings.allowRecurringJobWhileVolumeDetached == true &&
      length(kubernetes_secret_v1.longhorn_backup_s3) == 1
    )
    error_message = "Detached Longhorn volumes must be eligible for recurring backups and have an S3 credential Secret."
  }
}

run "keeping_hcloud_default_leaves_its_class_alone" {
  command = plan

  variables {
    config = {
      cluster_name           = "rke2-vtafarm-production"
      longhorn_default_class = false
      storage_class          = ""
    }
  }

  assert {
    condition     = length(kubernetes_annotations.hcloud_volumes_not_default) == 0
    error_message = "Nothing should touch the hcloud-volumes class when it stays the default."
  }

  # An empty storage_class means "cluster default", which the template has to
  # express by omitting the key entirely - an empty string would be a class name.
  assert {
    condition = (
      !strcontains(helm_release.vault.values[0], "storageClass:") &&
      !strcontains(helm_release.vault_transit.values[0], "storageClass:")
    )
    error_message = "An empty storage_class must omit storageClass, not emit a blank one."
  }
}

run "rejects_even_vault_replicas" {
  command = plan

  variables {
    config = {
      cluster_name   = "rke2-vtafarm-production"
      vault_replicas = 2
    }
  }

  expect_failures = [var.config]
}

run "rejects_sharing_one_namespace" {
  command = plan

  variables {
    config = {
      cluster_name      = "rke2-vtafarm-production"
      vault_namespace   = "vault"
      transit_namespace = "vault"
    }
  }

  expect_failures = [var.config]
}

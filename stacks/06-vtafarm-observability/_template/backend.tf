# No site values here: bucket, region and key arrive from -backend-config, which
# is why every init goes through make. See docs/remote-state.md.
terraform {
  backend "s3" {
    use_path_style = true
    use_lockfile   = true

    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
  }
}

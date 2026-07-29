# ============================================================
# tenant-integrations — outbound integrations + scheduled reports.
#
# Native provider resources only (no scripts), so these get real plan diffs
# and drift detection.
# ============================================================

locals {
  # Key by name for stable state addressing — list indices would cause
  # needless recreation whenever an entry is added or removed mid-list.
  integrations = { for i in var.integrations : i.name => i }
  reports      = { for r in var.reports : r.name => r }
}

# ------------------------------------------------------------
# Outbound integrations.
#
# integration_config is a required (min_items = 1) nested block, so it is
# always emitted exactly once. Unset optional fields pass through as null and
# are omitted from the API request.
# ------------------------------------------------------------
resource "prismacloud_integration" "this" {
  for_each = var.enabled ? local.integrations : {}

  name             = each.value.name
  integration_type = each.value.integration_type
  description      = each.value.description
  enabled          = each.value.enabled

  integration_config {
    url         = each.value.config.url
    base_url    = each.value.config.base_url
    host_url    = each.value.config.host_url
    webhook_url = each.value.config.webhook_url
    queue_url   = each.value.config.queue_url
    s3_uri      = each.value.config.s3_uri
    domain      = each.value.config.domain
    region      = each.value.config.region

    login      = each.value.config.login
    user_name  = each.value.config.user_name
    password   = each.value.config.password
    api_key    = each.value.config.api_key
    api_token  = each.value.config.api_token
    auth_token = each.value.config.auth_token
    access_key = each.value.config.access_key
    secret_key = each.value.config.secret_key

    integration_key = each.value.config.integration_key
    private_key     = each.value.config.private_key
    pass_phrase     = each.value.config.pass_phrase

    account_id  = each.value.config.account_id
    org_id      = each.value.config.org_id
    external_id = each.value.config.external_id
    role_arn    = each.value.config.role_arn

    source_id              = each.value.config.source_id
    source_type            = each.value.config.source_type
    connection_string      = each.value.config.connection_string
    pipe_name              = each.value.config.pipe_name
    staging_integration_id = each.value.config.staging_integration_id
    roll_up_interval       = each.value.config.roll_up_interval
    more_info              = each.value.config.more_info
    tables                 = each.value.config.tables
  }
}

# ------------------------------------------------------------
# Reports. `target` is a required (min_items = 1) nested block.
# ------------------------------------------------------------
resource "prismacloud_report" "this" {
  for_each = var.enabled ? local.reports : {}

  name        = each.value.name
  report_type = each.value.report_type
  cloud_type  = each.value.cloud_type

  target {
    account_groups          = each.value.target.account_groups
    accounts                = each.value.target.accounts
    regions                 = each.value.target.regions
    resource_groups         = each.value.target.resource_groups
    compliance_standard_ids = each.value.target.compliance_standard_ids

    notify_to                = each.value.target.notify_to
    notification_template_id = each.value.target.notification_template_id

    schedule            = each.value.target.schedule
    schedule_enabled    = each.value.target.schedule_enabled
    compression_enabled = each.value.target.compression_enabled
    download_now        = each.value.target.download_now
  }
}

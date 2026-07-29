# ============================================================
# tenant-inventory — read the tenant's settings and configuration.
#
# ⚠️  READ-ONLY BY CONSTRUCTION.
# Every block below is a `data` block. There are NO `resource` blocks in this
# module, which means Terraform has no way to create, update or delete
# anything here — a plan against this module can only ever report, never
# change. No apply gate is needed because there is nothing to apply.
#
# Each category is gated by `count` on the requested scope, so narrowing the
# scope genuinely skips the API call rather than just filtering the output.
# ============================================================

locals {
  all = var.scope == "all"

  # Per-category switches. A category is read when the module is enabled AND
  # either the scope is "all" or the scope names that category specifically.
  want_enterprise_settings   = var.enabled && (local.all || var.scope == "enterprise-settings")
  want_trusted_ips           = var.enabled && (local.all || var.scope == "trusted-ips")
  want_integrations          = var.enabled && (local.all || var.scope == "integrations")
  want_reports               = var.enabled && (local.all || var.scope == "reports")
  want_notification_template = var.enabled && (local.all || var.scope == "notification-templates")
  want_anomaly_settings      = var.enabled && (local.all || var.scope == "anomaly-settings")
}

# ------------------------------------------------------------
# Enterprise settings (singleton).
# ------------------------------------------------------------
data "prismacloud_enterprise_settings" "this" {
  count = local.want_enterprise_settings ? 1 : 0
}

# ------------------------------------------------------------
# Trusted IPs — login (who may sign in) and alert (internal ranges).
# ------------------------------------------------------------
data "prismacloud_trusted_login_ips" "this" {
  count = local.want_trusted_ips ? 1 : 0
}

data "prismacloud_trusted_alert_ips" "this" {
  count = local.want_trusted_ips ? 1 : 0
}

# ------------------------------------------------------------
# Outbound integrations.
# ------------------------------------------------------------
data "prismacloud_integrations" "this" {
  count = local.want_integrations ? 1 : 0
}

# ------------------------------------------------------------
# Reports.
# ------------------------------------------------------------
data "prismacloud_reports" "this" {
  count = local.want_reports ? 1 : 0
}

# ------------------------------------------------------------
# Notification templates.
# ------------------------------------------------------------
data "prismacloud_notification_templates" "this" {
  count = local.want_notification_template ? 1 : 0
}

# ------------------------------------------------------------
# Anomaly settings. The provider requires a `type` argument here.
# ------------------------------------------------------------
data "prismacloud_anomaly_settings" "this" {
  count = local.want_anomaly_settings ? 1 : 0

  type = var.anomaly_settings_type
}

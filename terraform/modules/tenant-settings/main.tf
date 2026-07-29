# ============================================================
# tenant-settings — tenant-wide enterprise settings.
#
# Unlike compute-runtime-policies (which needs scripts because the provider
# exposes no data source for runtime policies), everything here is NATIVE:
# a real resource + a real data source. That gives us proper plan diffs,
# drift detection and state tracking, with no bash/jq involved.
#
# SINGLETON + ADOPTION: a live tenant always already has enterprise settings.
# The `import` block below adopts that existing object on first apply instead
# of colliding with it. The provider uses a fixed ID for this singleton.
# ============================================================

# ------------------------------------------------------------
# READ-ONLY view of the tenant's current enterprise settings.
# Always safe; exposed via outputs for inspection/auditing.
# ------------------------------------------------------------
data "prismacloud_enterprise_settings" "current" {
  count = var.enabled ? 1 : 0
}

# ------------------------------------------------------------
# ADOPTION NOTE
#
# A live tenant ALREADY has an enterprise settings singleton, so the first
# apply must import it rather than create a duplicate. Terraform only permits
# `import` blocks in the ROOT module, so the adoption lives in the root
# configuration (see terraform/main.tf) rather than here. The adopt_existing
# variable documents that intent for callers.
# ------------------------------------------------------------

# ------------------------------------------------------------
# MANAGED enterprise settings.
#
# Every optional attribute passes through null when unset, which Terraform
# omits from the request — so we only change what was explicitly configured
# and never blank out a setting the caller didn't mention.
# ------------------------------------------------------------
resource "prismacloud_enterprise_settings" "this" {
  count = var.enabled ? 1 : 0

  access_key_max_validity = var.access_key_max_validity

  session_timeout                  = var.session_timeout
  alarm_enabled                    = var.alarm_enabled
  audit_logs_enabled               = var.audit_logs_enabled
  audit_log_siem_intgr_ids         = var.audit_log_siem_intgr_ids
  apply_default_policies_enabled   = var.apply_default_policies_enabled
  default_policies_enabled         = var.default_policies_enabled
  require_alert_dismissal_note     = var.require_alert_dismissal_note
  user_attribution_in_notification = var.user_attribution_in_notification

  named_users_access_keys_expiry_notifications_enabled   = var.named_users_access_keys_expiry_notifications_enabled
  service_users_access_keys_expiry_notifications_enabled = var.service_users_access_keys_expiry_notifications_enabled
  notification_threshold_access_keys_expiry              = var.notification_threshold_access_keys_expiry

  lifecycle {
    # Enterprise settings are tenant-wide and destructive to lose. This object
    # should only ever be updated in place, never destroyed and recreated.
    prevent_destroy = true

    precondition {
      condition     = var.access_key_max_validity != null
      error_message = "access_key_max_validity is required by the provider whenever tenant-settings is enabled. Set it explicitly."
    }
  }
}

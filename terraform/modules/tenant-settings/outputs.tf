# ----------------------------------------------------------------
# tenant-settings outputs. All are null when the module is disabled.
# ----------------------------------------------------------------

output "enterprise_settings_id" {
  description = "ID of the managed enterprise settings singleton. Null when the module is disabled."
  value       = var.enabled ? prismacloud_enterprise_settings.this[0].id : null
}

output "current_enterprise_settings" {
  description = "Read-only snapshot of the tenant's enterprise settings as they exist in the tenant (from the data source). Useful for auditing/diffing before managing them. Null when the module is disabled."
  value = var.enabled ? {
    session_timeout                  = data.prismacloud_enterprise_settings.current[0].session_timeout
    access_key_max_validity          = data.prismacloud_enterprise_settings.current[0].access_key_max_validity
    alarm_enabled                    = data.prismacloud_enterprise_settings.current[0].alarm_enabled
    audit_logs_enabled               = data.prismacloud_enterprise_settings.current[0].audit_logs_enabled
    apply_default_policies_enabled   = data.prismacloud_enterprise_settings.current[0].apply_default_policies_enabled
    require_alert_dismissal_note     = data.prismacloud_enterprise_settings.current[0].require_alert_dismissal_note
    user_attribution_in_notification = data.prismacloud_enterprise_settings.current[0].user_attribution_in_notification
  } : null
}

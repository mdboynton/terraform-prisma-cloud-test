# ----------------------------------------------------------------
# tenant-inventory outputs (read-only).
#
# Categories outside the requested scope are null, which distinguishes
# "not looked at" from an empty [] meaning "looked, found nothing".
# ----------------------------------------------------------------

locals {
  enterprise_settings = local.want_enterprise_settings ? {
    session_timeout         = data.prismacloud_enterprise_settings.this[0].session_timeout
    access_key_max_validity = data.prismacloud_enterprise_settings.this[0].access_key_max_validity

    alarm_enabled                    = data.prismacloud_enterprise_settings.this[0].alarm_enabled
    audit_logs_enabled               = data.prismacloud_enterprise_settings.this[0].audit_logs_enabled
    audit_log_siem_intgr_ids         = data.prismacloud_enterprise_settings.this[0].audit_log_siem_intgr_ids
    apply_default_policies_enabled   = data.prismacloud_enterprise_settings.this[0].apply_default_policies_enabled
    default_policies_enabled         = data.prismacloud_enterprise_settings.this[0].default_policies_enabled
    require_alert_dismissal_note     = data.prismacloud_enterprise_settings.this[0].require_alert_dismissal_note
    user_attribution_in_notification = data.prismacloud_enterprise_settings.this[0].user_attribution_in_notification

    named_users_access_keys_expiry_notifications_enabled   = data.prismacloud_enterprise_settings.this[0].named_users_access_keys_expiry_notifications_enabled
    service_users_access_keys_expiry_notifications_enabled = data.prismacloud_enterprise_settings.this[0].service_users_access_keys_expiry_notifications_enabled
    notification_threshold_access_keys_expiry              = data.prismacloud_enterprise_settings.this[0].notification_threshold_access_keys_expiry
  } : null

  trusted_login_ips = local.want_trusted_ips ? [
    for e in data.prismacloud_trusted_login_ips.this[0].listing : {
      name        = e.name
      cidr        = e.cidr
      description = e.description
      id          = e.trusted_login_ip_id
    }
  ] : null

  trusted_alert_ips = local.want_trusted_ips ? [
    for g in data.prismacloud_trusted_alert_ips.this[0].listing : {
      name       = g.name
      uuid       = g.uuid
      cidr_count = g.cidr_count
      cidrs      = [for c in g.cidrs : { cidr = c.cidr, description = c.description }]
    }
  ] : null

  integrations = local.want_integrations ? [
    for i in data.prismacloud_integrations.this[0].listing : {
      name             = i.name
      integration_type = i.integration_type
      integration_id   = i.integration_id
      description      = i.description
      enabled          = i.enabled
      status           = i.status
      valid            = i.valid
    }
  ] : null

  reports = local.want_reports ? [
    for r in data.prismacloud_reports.this[0].listing : {
      name        = r.name
      report_type = r.report_type
      report_id   = r.report_id
      cloud_type  = r.cloud_type
      status      = r.status
    }
  ] : null

  notification_templates = local.want_notification_template ? [
    for t in data.prismacloud_notification_templates.this[0].listing : {
      name             = t.name
      id               = t.id
      integration_type = t.integration_type
      integration_name = t.integration_name
      template_type    = t.template_type
      enabled          = t.enabled
      module           = t.module
    }
  ] : null

  anomaly_settings = local.want_anomaly_settings ? [
    for a in data.prismacloud_anomaly_settings.this[0].listing : {
      policy_name              = a.policy_name
      policy_id                = a.policy_id
      alert_disposition        = a.alert_disposition
      training_model_threshold = a.training_model_threshold
    }
  ] : null
}

output "inventory" {
  description = "Read-only snapshot of tenant-level settings and configuration, keyed by category. A category is null when it was outside the requested scope (as opposed to [] meaning it was read and is empty)."
  value = var.enabled ? {
    enterprise_settings    = local.enterprise_settings
    trusted_login_ips      = local.trusted_login_ips
    trusted_alert_ips      = local.trusted_alert_ips
    integrations           = local.integrations
    reports                = local.reports
    notification_templates = local.notification_templates
    anomaly_settings       = local.anomaly_settings
  } : null
}

output "summary" {
  description = "Compact count-per-category view, for an at-a-glance check without scrolling the full dump. Null for categories outside the requested scope."
  value = var.enabled ? {
    scope                  = var.scope
    enterprise_settings    = local.enterprise_settings == null ? null : "present"
    trusted_login_ips      = local.trusted_login_ips == null ? null : length(local.trusted_login_ips)
    trusted_alert_ips      = local.trusted_alert_ips == null ? null : length(local.trusted_alert_ips)
    integrations           = local.integrations == null ? null : length(local.integrations)
    reports                = local.reports == null ? null : length(local.reports)
    notification_templates = local.notification_templates == null ? null : length(local.notification_templates)
    anomaly_settings       = local.anomaly_settings == null ? null : length(local.anomaly_settings)
  } : null
}

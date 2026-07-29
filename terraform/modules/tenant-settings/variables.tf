# ============================================================
# tenant-settings module inputs
#
# Manages TENANT-WIDE enterprise settings via the native
# prismacloud_enterprise_settings resource (no scripts needed — unlike
# compute-runtime-policies, the provider exposes this natively).
#
# SINGLETON: there is exactly one enterprise settings object per tenant. It
# ALREADY EXISTS, so this module must ADOPT it (see adopt_existing) rather than
# try to create a new one.
#
# SAFETY: every optional setting defaults to null, which means "leave the
# tenant's current value alone". Only settings you explicitly set are managed.
# ============================================================

variable "enabled" {
  description = "(Optional) Master switch. When false, this module manages nothing (no reads, no writes). Default false so the module is inert until deliberately turned on."
  type        = bool
  default     = false
}

variable "adopt_existing" {
  description = "(Optional) When true, the module imports the tenant's pre-existing enterprise settings singleton into state on first apply instead of colliding with it. Enterprise settings always exist in a live tenant, so this should normally stay true."
  type        = bool
  default     = true
}

# ------------------------------------------------------------
# Enterprise settings. Attributes mirror prismacloud_enterprise_settings.
# access_key_max_validity is REQUIRED by the provider; the rest are optional.
# ------------------------------------------------------------

variable "access_key_max_validity" {
  description = "(Required when enabled) Maximum validity, in days, for tenant access keys. The provider requires this attribute, so it must be supplied whenever this module is enabled."
  type        = number
  default     = null

  validation {
    condition     = var.access_key_max_validity == null || (var.access_key_max_validity > 0 && var.access_key_max_validity <= 3650)
    error_message = "The access_key_max_validity must be between 1 and 3650 days."
  }
}

variable "session_timeout" {
  description = "(Optional) Idle session timeout in minutes. Null leaves the tenant's current value unchanged."
  type        = number
  default     = null

  validation {
    condition     = var.session_timeout == null || var.session_timeout > 0
    error_message = "The session_timeout must be a positive number of minutes."
  }
}

variable "alarm_enabled" {
  description = "(Optional) Whether alarms are enabled tenant-wide. Null leaves the current value unchanged."
  type        = bool
  default     = null
}

variable "audit_logs_enabled" {
  description = "(Optional) Whether audit logging is enabled. Null leaves the current value unchanged."
  type        = bool
  default     = null
}

variable "audit_log_siem_intgr_ids" {
  description = "(Optional) Set of SIEM integration IDs that audit logs are forwarded to. Null leaves the current value unchanged."
  type        = set(string)
  default     = null
}

variable "apply_default_policies_enabled" {
  description = "(Optional) Whether newly onboarded accounts get the default policy set applied. Null leaves the current value unchanged."
  type        = bool
  default     = null
}

variable "default_policies_enabled" {
  description = "(Optional) Map of policy severity => enabled, controlling which default policies are switched on. Null leaves the current value unchanged."
  type        = map(bool)
  default     = null
}

variable "require_alert_dismissal_note" {
  description = "(Optional) Whether users must supply a note when dismissing an alert. Null leaves the current value unchanged."
  type        = bool
  default     = null
}

variable "user_attribution_in_notification" {
  description = "(Optional) Whether notifications include the attributed user. Null leaves the current value unchanged."
  type        = bool
  default     = null
}

variable "named_users_access_keys_expiry_notifications_enabled" {
  description = "(Optional) Whether named users receive access-key expiry notifications. Null leaves the current value unchanged."
  type        = bool
  default     = null
}

variable "service_users_access_keys_expiry_notifications_enabled" {
  description = "(Optional) Whether service users receive access-key expiry notifications. Null leaves the current value unchanged."
  type        = bool
  default     = null
}

variable "notification_threshold_access_keys_expiry" {
  description = "(Optional) Days before access-key expiry at which notifications are sent. Null leaves the current value unchanged."
  type        = number
  default     = null

  validation {
    condition     = var.notification_threshold_access_keys_expiry == null || var.notification_threshold_access_keys_expiry >= 0
    error_message = "The notification_threshold_access_keys_expiry must be a non-negative number of days."
  }
}

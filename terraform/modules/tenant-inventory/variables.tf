# ============================================================
# tenant-inventory module inputs — STRICTLY READ-ONLY.
#
# This module contains ONLY `data` blocks. There is not a single `resource`
# in it, so it is structurally incapable of creating, modifying or deleting
# anything in the tenant. There is nothing to gate and no apply to approve.
# ============================================================

variable "enabled" {
  description = "(Optional) When true, read the tenant's settings/configuration and expose them as outputs. Read-only. Default false so callers that don't want the extra API calls pay nothing."
  type        = bool
  default     = false
}

variable "scope" {
  description = "(Optional) Which category to read. \"all\" (default) reads everything; narrowing to a single category skips the other API calls and keeps the output focused. One of: all, enterprise-settings, trusted-ips, integrations, reports, notification-templates, anomaly-settings."
  type        = string
  default     = "all"

  validation {
    condition = contains([
      "all",
      "enterprise-settings",
      "trusted-ips",
      "integrations",
      "reports",
      "notification-templates",
      "anomaly-settings",
    ], var.scope)
    error_message = "The scope must be one of: all, enterprise-settings, trusted-ips, integrations, reports, notification-templates, anomaly-settings."
  }
}

variable "anomaly_settings_type" {
  description = "(Optional) The anomaly settings type to read; the provider requires this argument for the anomaly settings data source. Defaults to \"network\"."
  type        = string
  default     = "network"
}

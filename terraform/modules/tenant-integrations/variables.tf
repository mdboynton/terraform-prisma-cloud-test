# ============================================================
# tenant-integrations module inputs
#
# Manages tenant-level outbound integrations and scheduled reports using the
# native provider resources (prismacloud_integration, prismacloud_report).
#
# NOTE: notification templates (prismacloud_notification_template) are
# deliberately NOT handled here yet — their template_config requires five
# nested severity blocks (basic_config/open/resolved/dismissed/snoozed) and
# warrants its own slice. Reports can still reference an existing template by
# ID via target.notification_template_id.
# ============================================================

variable "enabled" {
  description = "(Optional) Master switch. When false, this module manages nothing. Default false so the module is inert until deliberately turned on."
  type        = bool
  default     = false
}

# ------------------------------------------------------------
# Outbound integrations (SIEM, ticketing, chat, storage, ...).
#
# integration_config mirrors the provider's optional credential/endpoint
# fields. Only set the ones your integration_type actually requires — the rest
# stay null and are omitted from the request.
# ------------------------------------------------------------

variable "integrations" {
  description = "(Optional) Outbound integrations: list of { name, integration_type, description, enabled, config }. The config object carries only the credential/endpoint fields relevant to the chosen integration_type; unset fields are omitted. Empty = manage no integrations."
  type = list(object({
    name             = string
    integration_type = string
    description      = optional(string)
    enabled          = optional(bool, true)

    config = object({
      # Endpoints / addressing
      url         = optional(string)
      base_url    = optional(string)
      host_url    = optional(string)
      webhook_url = optional(string)
      queue_url   = optional(string)
      s3_uri      = optional(string)
      domain      = optional(string)
      region      = optional(string)

      # Identity / credentials (sensitive values — see the module README).
      login      = optional(string)
      user_name  = optional(string)
      password   = optional(string)
      api_key    = optional(string)
      api_token  = optional(string)
      auth_token = optional(string)
      access_key = optional(string)
      secret_key = optional(string)

      integration_key = optional(string)
      private_key     = optional(string)
      pass_phrase     = optional(string)

      # Cloud / account scoping
      account_id  = optional(string)
      org_id      = optional(string)
      external_id = optional(string)
      role_arn    = optional(string)

      # Misc provider-specific knobs
      source_id              = optional(string)
      source_type            = optional(string)
      connection_string      = optional(string)
      pipe_name              = optional(string)
      staging_integration_id = optional(string)
      roll_up_interval       = optional(number)
      more_info              = optional(bool)
      tables                 = optional(map(bool))
    })
  }))
  default = []

  # NOTE: this variable is deliberately NOT marked `sensitive` as a whole.
  # Doing so would taint the derived for_each map, and Terraform forbids
  # sensitive values as for_each keys (the key would leak into resource
  # addresses). Integration NAMES are not secrets; the credential fields inside
  # `config` are, and those are handled by marking the credential-carrying
  # outputs sensitive and by passing secrets in from sensitive root variables.

  validation {
    condition = alltrue([
      for i in var.integrations : length(i.name) > 0 && length(i.integration_type) > 0
    ])
    error_message = "Each integrations entry must have a non-empty name and integration_type."
  }

  validation {
    condition     = length(distinct([for i in var.integrations : i.name])) == length(var.integrations)
    error_message = "The integrations names must be unique."
  }
}

# ------------------------------------------------------------
# Scheduled / on-demand reports.
# ------------------------------------------------------------

variable "reports" {
  description = "(Optional) Reports: list of { name, report_type, cloud_type, target }. The target object controls scope (accounts, account groups, regions, compliance standards) and delivery (notify_to, schedule, notification_template_id). Empty = manage no reports."
  type = list(object({
    name        = string
    report_type = string
    cloud_type  = optional(string)

    target = object({
      account_groups          = optional(set(string))
      accounts                = optional(set(string))
      regions                 = optional(set(string))
      resource_groups         = optional(set(string))
      compliance_standard_ids = optional(set(string))

      notify_to                = optional(set(string))
      notification_template_id = optional(string)

      schedule            = optional(string)
      schedule_enabled    = optional(bool)
      compression_enabled = optional(bool)
      download_now        = optional(bool)
    })
  }))
  default = []

  validation {
    condition = alltrue([
      for r in var.reports : length(r.name) > 0 && length(r.report_type) > 0
    ])
    error_message = "Each reports entry must have a non-empty name and report_type."
  }

  validation {
    condition     = length(distinct([for r in var.reports : r.name])) == length(var.reports)
    error_message = "The reports names must be unique."
  }

  validation {
    condition = alltrue([
      for r in var.reports :
      r.target.schedule_enabled != true || try(length(r.target.schedule), 0) > 0
    ])
    error_message = "A report with target.schedule_enabled = true must also define target.schedule."
  }
}

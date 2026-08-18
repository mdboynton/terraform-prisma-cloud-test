variable "enabled" {
  description = "(Optional) Report the enforcement effect of runtime rules that are producing alerts. Default false so this module costs nothing in workflows that don't need it."
  type        = bool
  default     = false
  nullable    = false
}

variable "window_days" {
  description = "(Optional) How far back to look for promoted runtime alerts. Only rules that produced an alert inside this window are reported."
  type        = number
  default     = 14
  nullable    = false

  validation {
    condition     = var.window_days >= 1 && var.window_days <= 3650
    error_message = "window_days must be between 1 and 3650."
  }
}

variable "alert_status" {
  description = "(Optional) Which alert lifecycle state to report on. NOTE: this materially changes which rules appear - rules whose alerts have all been resolved or dismissed are invisible under the default `open`."
  type        = string
  default     = "open"
  nullable    = false

  validation {
    condition     = contains(["open", "resolved", "dismissed", "snoozed"], var.alert_status)
    error_message = "alert_status must be one of: open, resolved, dismissed, snoozed."
  }
}

variable "max_alerts" {
  description = "(Optional) Cap on how many alerts are fetched before grouping by rule."
  type        = number
  default     = 2000
  nullable    = false

  validation {
    condition     = var.max_alerts >= 1 && var.max_alerts <= 10000
    error_message = "max_alerts must be between 1 and 10000."
  }
}

variable "skip_cert_verification" {
  description = "(Optional) Skip TLS verification when talking to the Compute Console. For self-signed on-prem consoles only - never for a SaaS tenant."
  type        = bool
  default     = false
  nullable    = false
}

# ----------------------------------------------------------------
# The write path.
#
# Everything above this line is read-only. Everything below can change
# enforcement on a live runtime policy.
#
# Escalations are NEVER derived automatically from `alerting_sites`. The
# module reports candidates; a human names the ones to change. Auto-deriving
# would mean a wider alert window silently escalates more rules, which is
# exactly the kind of surprise a blocking change must not have.
# ----------------------------------------------------------------

variable "escalations" {
  description = "(Optional) Explicit list of effect sites to escalate. Each entry is {kind, rule, site, effect}, where `site` is the literal jq path reported in the `sites` output. Empty means nothing is written."
  type = list(object({
    kind   = string
    rule   = string
    site   = string
    effect = string
  }))
  default  = []
  nullable = false

  validation {
    condition     = alltrue([for e in var.escalations : contains(["container", "host"], e.kind)])
    error_message = "Each escalation kind must be either \"container\" or \"host\"."
  }

  validation {
    condition     = alltrue([for e in var.escalations : contains(["alert", "prevent", "block"], e.effect)])
    error_message = "Each escalation effect must be one of: alert, prevent, block. `disable` is refused - turning a detection off is not an escalation."
  }

  # VERIFIED: the effect vocabulary differs by workload type. `block` is a
  # container-only value; a host rule rejects it. Catching this in the plan is
  # far better than catching it in a PUT that half-succeeded.
  validation {
    condition     = alltrue([for e in var.escalations : !(e.kind == "host" && e.effect == "block")])
    error_message = "`block` is not a valid effect for a host rule - use `prevent`. The effect vocabulary differs by workload type."
  }

  validation {
    condition     = alltrue([for e in var.escalations : trimspace(e.rule) != "" && trimspace(e.site) != ""])
    error_message = "Each escalation must name a non-empty rule and site."
  }
}

variable "apply_escalations" {
  description = "(Optional) Must be the exact string \"APPLY\" for any write to occur. Anything else - including true, yes, or apply - leaves this module read-only. A word rather than a boolean, because booleans accumulate in CI defaults."
  type        = string
  default     = ""
  nullable    = false
}

# ----------------------------------------------------------------
# Credentials.
#
# THIS MODULE NEEDS BOTH APIS, and that is not an accident of design.
#
# VERIFIED against 100 promoted alerts: the CSPM alert carries NO effect field
# at any depth. Enforcement state (alert / prevent / block / disable) exists
# only inside the Compute Console policy objects. Answering "is this firing rule
# still only alerting?" therefore requires reading the alert stream from CSPM
# and the rule state from Compute, then joining them.
#
# The access key and secret are shared across both; only the hosts differ.
# ----------------------------------------------------------------

variable "cspm_url" {
  description = "(Optional) Prisma Cloud CSPM API host, e.g. \"api2.prismacloud.io\". Required when enabled is true. A missing scheme is tolerated."
  type        = string
  default     = null
}

variable "compute_url" {
  description = "(Optional) Compute Console URL. Required when enabled is true. MUST include the path prefix, e.g. \"https://us-east1.cloud.twistlock.com/us-2-158320372\" - without it authentication returns HTTP 404 or an empty token."
  type        = string
  default     = null
}

variable "access_key" {
  description = "(Optional) Prisma Cloud access key id. Required when enabled is true."
  type        = string
  default     = null
  sensitive   = true
}

variable "secret_key" {
  description = "(Optional) Prisma Cloud secret key. Required when enabled is true."
  type        = string
  default     = null
  sensitive   = true
}

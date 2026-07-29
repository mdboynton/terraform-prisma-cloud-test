# ============================================================
# tenant-access module inputs
#
# Manages TENANT-WIDE network access controls:
#   - trusted LOGIN IPs  (prismacloud_trusted_login_ip)  — who may log in
#   - login IP ENFORCEMENT (prismacloud_trusted_login_ip_status)
#   - trusted ALERT IPs  (prismacloud_trusted_alert_ip)  — internal-IP alerting
#
# ⚠️  HIGHEST BLAST RADIUS IN THE REPO.
# Enabling login-IP enforcement with an incomplete CIDR list can LOCK EVERY
# USER (including you) OUT OF THE TENANT. This module is deliberately isolated
# from other tenant config so an unrelated change can never drag it along, and
# enforcement is a separate, explicit opt-in from defining the allowlist.
# ============================================================

variable "enabled" {
  description = "(Optional) Master switch. When false, this module manages nothing. Default false so the module is inert until deliberately turned on."
  type        = bool
  default     = false
}

# ------------------------------------------------------------
# Trusted LOGIN IPs — the allowlist itself.
# Defining the list is SAFE on its own; nothing is enforced until
# enforce_login_ip_allowlist is set to true.
# ------------------------------------------------------------

variable "trusted_login_ips" {
  description = "(Optional) Trusted login IP allowlist entries: list of { name, cidrs, description }. Defining entries alone does NOT enforce anything — enforcement is controlled separately by enforce_login_ip_allowlist. Empty = manage no login IP entries."
  type = list(object({
    name        = string
    cidrs       = set(string)
    description = optional(string)
  }))
  default = []

  validation {
    condition     = alltrue([for e in var.trusted_login_ips : length(e.name) > 0])
    error_message = "Each trusted_login_ips entry must have a non-empty name."
  }

  validation {
    condition     = alltrue([for e in var.trusted_login_ips : length(e.cidrs) > 0])
    error_message = "Each trusted_login_ips entry must list at least one CIDR."
  }

  validation {
    condition = alltrue(flatten([
      for e in var.trusted_login_ips : [
        for c in e.cidrs : can(cidrnetmask(c))
      ]
    ]))
    error_message = "Every trusted_login_ips CIDR must be valid CIDR notation (e.g. \"203.0.113.0/24\")."
  }

  validation {
    condition     = length(distinct([for e in var.trusted_login_ips : e.name])) == length(var.trusted_login_ips)
    error_message = "The trusted_login_ips entry names must be unique."
  }
}

variable "enforce_login_ip_allowlist" {
  description = "(Optional) ⚠️ DANGEROUS. When true, Prisma Cloud REJECTS logins from any IP outside the trusted login IP allowlist, tenant-wide. An incomplete list will lock everyone out, including automation. Leave null to not manage the enforcement toggle at all (recommended); set explicitly only when you are certain the allowlist is complete."
  type        = bool
  default     = null
}

variable "acknowledge_lockout_risk" {
  description = "(Optional) Safety interlock. Must be set to true in order to set enforce_login_ip_allowlist = true. This exists to make enabling tenant-wide login IP enforcement a deliberate, two-key action rather than a single flag flip."
  type        = bool
  default     = false
}

# ------------------------------------------------------------
# Trusted ALERT IPs — used to classify traffic as internal for alerting.
# Low risk: does not affect authentication.
# ------------------------------------------------------------

variable "trusted_alert_ips" {
  description = "(Optional) Trusted alert IP groups: list of { name, cidrs }, where cidrs is a list of { cidr, description }. These mark network ranges as internal for alerting purposes and do NOT affect login access. Empty = manage no alert IP groups."
  type = list(object({
    name = string
    cidrs = list(object({
      cidr        = string
      description = optional(string)
    }))
  }))
  default = []

  validation {
    condition     = alltrue([for g in var.trusted_alert_ips : length(g.name) > 0])
    error_message = "Each trusted_alert_ips group must have a non-empty name."
  }

  validation {
    condition = alltrue(flatten([
      for g in var.trusted_alert_ips : [
        for c in g.cidrs : can(cidrnetmask(c.cidr))
      ]
    ]))
    error_message = "Every trusted_alert_ips cidr must be valid CIDR notation (e.g. \"10.0.0.0/8\")."
  }

  validation {
    condition     = length(distinct([for g in var.trusted_alert_ips : g.name])) == length(var.trusted_alert_ips)
    error_message = "The trusted_alert_ips group names must be unique."
  }
}

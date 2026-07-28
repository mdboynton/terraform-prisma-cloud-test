# ============================================================
# compute-runtime-policies module inputs
#
# This module ATTACHES an RBAC collection to EXISTING Compute runtime policy
# rules (container + host). It does NOT create or redefine policies/rules — it
# only appends the named collection to a matched rule's `collections` list,
# preserving everything already there (mechanism B: API read-merge-write).
# ============================================================

# ------------------------------------------------------------
# Compute Console authentication (passed from the root module).
# The access key / secret key are the same as CSPM (D3).
# ------------------------------------------------------------

variable "console_url" {
  description = "(Required) Prisma Cloud Compute Console URL, e.g. \"https://us-east1.cloud.twistlock.com/us-2-158320372\"."
  type        = string

  validation {
    condition     = length(var.console_url) > 0
    error_message = "console_url must not be empty."
  }
}

variable "access_key" {
  description = "(Required) Prisma Cloud access key ID used to authenticate to the Compute Console API."
  type        = string
  sensitive   = true
}

variable "secret_key" {
  description = "(Required) Prisma Cloud secret key used to authenticate to the Compute Console API."
  type        = string
  sensitive   = true
}

variable "skip_cert_verification" {
  description = "(Optional) When true, skips TLS certificate verification for Compute Console API calls (passes -k to curl). Default false."
  type        = bool
  default     = false
}

# ------------------------------------------------------------
# Associations: which existing rule gets which collection appended.
# ------------------------------------------------------------

variable "container_associations" {
  description = "(Optional) List of { policy_rule_name, add_collection } describing which existing CONTAINER runtime policy rule (matched by exact name) should have the given collection appended to its `collections`. Empty = no container changes."
  type = list(object({
    policy_rule_name = string
    add_collection   = string
  }))
  default = []

  validation {
    condition = alltrue([
      for a in var.container_associations :
      length(a.policy_rule_name) > 0 && length(a.add_collection) > 0
    ])
    error_message = "Each container_associations entry must have a non-empty policy_rule_name and add_collection."
  }
}

variable "host_associations" {
  description = "(Optional) List of { policy_rule_name, add_collection } describing which existing HOST runtime policy rule (matched by exact name) should have the given collection appended to its `collections`. Empty = no host changes."
  type = list(object({
    policy_rule_name = string
    add_collection   = string
  }))
  default = []

  validation {
    condition = alltrue([
      for a in var.host_associations :
      length(a.policy_rule_name) > 0 && length(a.add_collection) > 0
    ])
    error_message = "Each host_associations entry must have a non-empty policy_rule_name and add_collection."
  }
}

# ------------------------------------------------------------
# Read-only listing (data source). Independent of associations.
# ------------------------------------------------------------

variable "enable_list" {
  description = "(Optional) When true, read both runtime policies (container + host) and expose two listing views: a full rule dump (Direction 1) and a collection -> rules index (Direction 2). Read-only; no writes. Default false."
  type        = bool
  default     = false
}

variable "list_collection_filter" {
  description = "(Optional) When set together with enable_list, restricts the `rules_by_collection` index to this single collection name (e.g. an RBAC artifact's collection). Empty = index every collection. The full_dump is always complete."
  type        = string
  default     = ""
}

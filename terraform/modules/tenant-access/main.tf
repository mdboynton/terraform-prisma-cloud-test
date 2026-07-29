# ============================================================
# tenant-access — tenant-wide network access controls.
#
# All native provider resources (no scripts): real plan diffs and drift
# detection, unlike the script-based compute-runtime-policies module.
#
# ⚠️  LOCKOUT WARNING
# prismacloud_trusted_login_ip_status.enabled = true makes Prisma Cloud reject
# logins from every IP not covered by the allowlist. If the allowlist is
# incomplete, ALL users and automation lose access to the tenant. Recovery
# requires Palo Alto support. This module therefore:
#   1. keeps defining the allowlist separate from enforcing it, and
#   2. requires an explicit acknowledge_lockout_risk interlock to enforce.
# ============================================================

locals {
  # Key by name so entries are addressed stably in state — using list indices
  # would cause churn//recreation whenever an entry is inserted or removed.
  login_ips = { for e in var.trusted_login_ips : e.name => e }
  alert_ips = { for g in var.trusted_alert_ips : g.name => g }

  # Enforcement is only managed when the caller explicitly set the toggle.
  manage_login_ip_status = var.enabled && var.enforce_login_ip_allowlist != null
}

# ------------------------------------------------------------
# Trusted LOGIN IP allowlist entries. Safe on their own — defining an entry
# does not restrict anything until enforcement is switched on below.
# ------------------------------------------------------------
resource "prismacloud_trusted_login_ip" "this" {
  for_each = var.enabled ? local.login_ips : {}

  name        = each.value.name
  cidr        = each.value.cidrs
  description = each.value.description
}

# ------------------------------------------------------------
# ⚠️ ENFORCEMENT of the login IP allowlist (tenant-wide).
#
# Guarded three ways: the module must be enabled, the caller must explicitly
# set enforce_login_ip_allowlist, and turning it ON additionally requires
# acknowledge_lockout_risk = true.
# ------------------------------------------------------------
resource "prismacloud_trusted_login_ip_status" "this" {
  count = local.manage_login_ip_status ? 1 : 0

  enabled = var.enforce_login_ip_allowlist

  depends_on = [prismacloud_trusted_login_ip.this]

  lifecycle {
    precondition {
      condition     = var.enforce_login_ip_allowlist != true || var.acknowledge_lockout_risk
      error_message = "Refusing to enable tenant-wide login IP enforcement: set acknowledge_lockout_risk = true to confirm you understand this can lock every user out of the tenant."
    }

    precondition {
      condition     = var.enforce_login_ip_allowlist != true || length(var.trusted_login_ips) > 0
      error_message = "Refusing to enable login IP enforcement with an empty allowlist — that would lock everyone out immediately. Define trusted_login_ips first."
    }
  }
}

# ------------------------------------------------------------
# Trusted ALERT IPs. Classify ranges as internal for alerting.
# Does not affect authentication, so no interlock is needed.
# ------------------------------------------------------------
resource "prismacloud_trusted_alert_ip" "this" {
  for_each = var.enabled ? local.alert_ips : {}

  name = each.value.name

  dynamic "cidrs" {
    for_each = each.value.cidrs
    content {
      cidr        = cidrs.value.cidr
      description = cidrs.value.description
    }
  }
}

# tenant-inventory

Lists tenant-level Prisma Cloud settings and configuration.

## Read-only by construction

This module contains **only Terraform `data` blocks — zero `resource` blocks**.
Terraform can only create, modify or delete things declared as resources, so
this module has no mechanism to change the tenant. That is a structural
guarantee, not a policy or a flag someone can flip:

```bash
# Returns nothing:
grep -r "^resource" terraform/modules/tenant-inventory/
```

Consequently there is no apply step, no approval gate, and no lockout risk. A
run can only report.

> Contrast with [`compute-runtime-policies`](../compute-runtime-policies),
> which needs shell scripts because the provider ships no data source for
> runtime policies, and which *does* have a (gated) write path. Everything here
> is native and read-only.

## Categories

| Scope value | Reads | Data source |
|---|---|---|
| `enterprise-settings` | Session timeout, access-key validity, audit logging, default policies | `prismacloud_enterprise_settings` |
| `trusted-ips` | Login IP allowlist + alert IP groups | `prismacloud_trusted_login_ips`, `prismacloud_trusted_alert_ips` |
| `integrations` | Outbound integrations and their health | `prismacloud_integrations` |
| `reports` | Configured reports | `prismacloud_reports` |
| `notification-templates` | Notification templates | `prismacloud_notification_templates` |
| `anomaly-settings` | Anomaly policy settings | `prismacloud_anomaly_settings` |
| `all` *(default)* | Everything above | — |

Scope gating uses `count`, so narrowing the scope **genuinely skips the API
call** rather than fetching everything and filtering afterwards.

## Usage

```hcl
module "tenant_inventory" {
  source = "./modules/tenant-inventory"

  enabled = true
  scope   = "all" # or a single category
}
```

Normally you don't call this directly — use the **Tenant Inventory (read-only)**
GitHub Actions workflow, which exposes `scope` as a dropdown.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `false` | Read the tenant when true. Off by default so callers pay no API cost. |
| `scope` | string | `"all"` | Category to read; validated against the list above. |
| `anomaly_settings_type` | string | `"network"` | Required by the provider's anomaly settings data source. |

## Outputs

| Name | Description |
|---|---|
| `inventory` | Full snapshot keyed by category. |
| `summary` | Count per category, for an at-a-glance view. |

**`null` vs `[]`** — a category is `null` when it was **outside the requested
scope** (never looked at), and `[]` when it *was* read and is genuinely empty.
The distinction matters when interpreting results.

## Verified against a live tenant

A `terraform plan` with `enabled = true` returned real data — 142 integrations,
291 reports, 65 notification templates, 27 alert IP groups, 3 login IPs, 10
anomaly settings — and contributed **zero** planned resource changes.

## Notes & caveats

- Integrations report `status` and `valid` as the tenant sees them; an
  integration can be `enabled = true` yet `valid = false` if its credentials
  fail validation. Useful for spotting silently-broken alert delivery.
- Reports and integrations can number in the hundreds. Use a narrower `scope`
  (or the workflow's `summary-only` output format) to keep logs readable.
- Adding another category means adding a `data` block and a `locals` entry —
  it stays read-only as long as no `resource` block is ever introduced here.

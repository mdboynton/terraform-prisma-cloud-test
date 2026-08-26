# tenant-inventory

Lists tenant-level Prisma Cloud settings and configuration. Read-only: `data` blocks only, no `resource` blocks.

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

Scope gating uses `count`, so narrowing the scope skips the API call entirely.

## Usage

```hcl
module "tenant_inventory" {
  source = "./modules/tenant-inventory"

  enabled = true
  scope   = "all" # or a single category
}
```

Normally called via the **Tenant Inventory (read-only)** GitHub Actions workflow.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `false` | Read the tenant when true. |
| `scope` | string | `"all"` | Category to read; validated against the list above. |
| `anomaly_settings_type` | string | `"network"` | Required by the provider's anomaly settings data source. |

## Outputs

| Name | Description |
|---|---|
| `inventory` | Full snapshot keyed by category. |
| `summary` | Count per category. |

`null` = outside the requested scope. `[]` = read and genuinely empty.

## Notes

- Integrations can be `enabled = true` yet `valid = false` if credentials fail validation.
- Reports and integrations can number in the hundreds — use a narrower `scope` or the workflow's `summary-only` format.

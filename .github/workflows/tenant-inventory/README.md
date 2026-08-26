# Workflow 3 — Tenant Inventory (read-only)

**Workflow file:** [`../tenant-inventory.yml`](../tenant-inventory.yml) · **Actions name:** `3. Tenant Inventory (read-only)`

Lists tenant-wide Prisma Cloud settings and configuration. Read-only: module has `data` blocks only, no apply job, no approval gate.

## How to use it

1. **Actions** → **3. Tenant Inventory (read-only)** → **Run workflow**
2. Pick a **scope** (defaults to `all`)
3. Pick an **output_format** (defaults to `summary-and-detail`)
4. **Run workflow**

### Scope options

| Scope | Shows |
|---|---|
| `all` *(default)* | Everything below |
| `enterprise-settings` | Session timeout, access-key validity, audit logging, default policies |
| `trusted-ips` | Login IP allowlist + alert IP groups |
| `integrations` | Outbound integrations and their health |
| `reports` | Configured reports |
| `notification-templates` | Notification templates |
| `anomaly-settings` | Anomaly policy settings |

Narrowing the scope skips the other API calls entirely.

### Output formats

| Format | Use when |
|---|---|
| `summary-and-detail` *(default)* | Normal use |
| `summary-only` | You just want counts |
| `detail-only` | You're copying the full JSON out |

## Where the results appear

1. **Run summary page** — counts table
2. **Job log** — full JSON under "Show results"
3. **Artifact** — `tenant-inventory-<scope>.json` (14-day retention)

## Reading the output

- `null` — category outside your scope (never looked at)
- `[]` — category read and genuinely empty

```json
{
  "scope": "all",
  "enterprise_settings": "present",
  "integrations": 142,
  "reports": 291,
  "notification_templates": 65,
  "trusted_alert_ips": 27,
  "trusted_login_ips": 3,
  "anomaly_settings": 10
}
```

An integration can be `enabled: true` but `valid: false` — credentials failing validation.

## Setup requirements

| Secret | Notes |
|---|---|
| `PRISMACLOUD_API_URL` | Tenant API host |
| `PRISMACLOUD_USERNAME` | Access key UUID |
| `PRISMACLOUD_PASSWORD` | Secret key |

No Environment or reviewer needed.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Workflow missing from the sidebar | `workflow_dispatch` workflows only appear once on the default branch. |
| `invalid credentials` | Refresh `PRISMACLOUD_USERNAME` / `PRISMACLOUD_PASSWORD`. |
| A category is `null` | It was outside the chosen scope. Re-run with `all`. |
| Log is huge | Use `summary-only`, or narrow the scope. |

## More detail

[`terraform/modules/tenant-inventory/README.md`](../../../terraform/modules/tenant-inventory/README.md)

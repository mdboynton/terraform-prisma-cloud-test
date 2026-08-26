# Workflow 3 — Tenant Inventory (read-only)

**Workflow file:** [`../tenant-inventory.yml`](../tenant-inventory.yml) · **Actions name:** `3. Tenant Inventory (read-only)`

Lists tenant-level Prisma Cloud settings and configuration.

## How to use it

1. **Actions** → **3. Tenant Inventory (read-only)** → **Run workflow**
2. Pick a **scope** (defaults to `all`)
3. **Run workflow**

### Scope options

| Scope value | Reads |
|---|---|
| `enterprise-settings` | Session timeout, access-key validity, audit logging, default policies |
| `trusted-ips` | Login IP allowlist + alert IP groups |
| `integrations` | Outbound integrations and their health |
| `reports` | Configured reports |
| `notification-templates` | Notification templates |
| `anomaly-settings` | Anomaly policy settings |
| `all` *(default)* | Everything above |

Narrowing the scope skips the other API calls entirely.

### Output formats

| Format | Use when |
|---|---|
| `summary-and-inventory` *(default)* | Normal use |
| `summary-only` | You just want the counts |
| `full-inventory` | You're exporting everything |

## Where the results appear

1. **Run summary page** — counts and tables
2. **Job log** — full JSON under the results step
3. **Artifact** — `tenant-inventory.json`, downloadable and diffable between runs

## Reading the output

- `null` — the category was outside your scope, never read.
- `[]` — the category was read and is genuinely empty.
- Integrations can be `enabled = true` yet `valid = false` if credentials fail validation.
- Reports and integrations can number in the hundreds — use a narrower `scope` or `summary-only`.

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
| Workflow missing from the sidebar | `workflow_dispatch` workflows only appear once on the **default branch**. |
| `invalid credentials` | Refresh `PRISMACLOUD_USERNAME` / `PRISMACLOUD_PASSWORD`. |
| A category is `null` | Outside the chosen scope. Re-run with `all`. |
| Run is slow | Large tenant. Narrow the scope or use `summary-only`. |

## More detail

Module internals and full output shape: [`terraform/modules/tenant-inventory/README.md`](../../../terraform/modules/tenant-inventory/README.md)

# Workflow 3 — Tenant Inventory (read-only)

**Workflow file:** [`../tenant-inventory.yml`](../tenant-inventory.yml) · **Actions name:** `3. Tenant Inventory (read-only)`

Lists tenant-wide Prisma Cloud settings and configuration.

**Can it change the tenant?** ❌ **No — and it structurally cannot.**

---

## Why "cannot" rather than "does not"

Terraform can only change things declared as a `resource`. The
[`tenant-inventory`](../../../terraform/modules/tenant-inventory/README.md)
module contains **only `data` blocks — zero `resource` blocks**:

```bash
$ grep -rc "^resource" terraform/modules/tenant-inventory/*.tf
0        # ← nothing to create, update or delete
```

So there is no apply job, no approval gate, and nothing to review. Run it as
often as you like.

---

## How to use it

1. **Actions** → **3. Tenant Inventory (read-only)** → **Run workflow**
2. Pick a **scope** (defaults to `all`)
3. Pick an **output_format** (defaults to `summary-and-detail`)
4. **Run workflow**

That's the whole procedure. No PR, no approval, no config editing.

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

Narrowing the scope genuinely **skips** the other API calls — it isn't just
output filtering.

### Output formats

| Format | Use when |
|---|---|
| `summary-and-detail` *(default)* | Normal use |
| `summary-only` | You just want counts — good for big categories |
| `detail-only` | You're copying the full JSON out |

## Where the results appear

1. **Run summary page** — counts table, visible without opening the log
2. **Job log** — full JSON under "Show results"
3. **Artifact** — `tenant-inventory-<scope>.json`, downloadable and diffable
   between runs (kept 14 days)

## Reading the output

**`null` vs `[]` matters:**

- `null` — the category was **outside your scope** (never looked at)
- `[]` — the category **was read** and is genuinely empty

Example summary from a real run:

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

An integration can be `enabled: true` but `valid: false` — accepted by the
tenant yet failing its credential check. Worth scanning for; it's the usual
cause of silently-missing alert delivery.

## Setup requirements

| Secret | Notes |
|---|---|
| `PRISMACLOUD_API_URL` | Tenant API host |
| `PRISMACLOUD_USERNAME` | Access key UUID |
| `PRISMACLOUD_PASSWORD` | Secret key |

No Environment or reviewer needed — there's nothing to gate.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Workflow missing from the sidebar | `workflow_dispatch` workflows only appear once they exist on the **default branch**. |
| `invalid credentials` | Refresh `PRISMACLOUD_USERNAME` / `PRISMACLOUD_PASSWORD`. |
| A category is `null` | It was outside the chosen scope. Re-run with `all`. |
| Log is huge | Use `summary-only`, or narrow the scope. |

## More detail

Module internals and the full output shape:
[`terraform/modules/tenant-inventory/README.md`](../../../terraform/modules/tenant-inventory/README.md)

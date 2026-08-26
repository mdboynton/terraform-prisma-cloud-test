# Workflow 4 — Access Audit (read-only)

**Workflow file:** [`../access-audit.yml`](../access-audit.yml) · **Actions name:** `4. Access Audit (read-only)`

Roles, user profiles, and permission groups, plus the subset of rows an access review acts on.

**Can it change the tenant?** No — `data` blocks only, zero `resource` blocks. No apply job, no approval gate.

## How to use it

1. **Actions** → **4. Access Audit (read-only)** → **Run workflow**
2. Pick a **scope** (defaults to `all`)
3. Pick an **output_format** (defaults to `summary-and-findings`)
4. **Run workflow**

### Scope options

| Scope | Shows |
|---|---|
| `all` *(default)* | Everything below |
| `roles` | Roles, their type, account-group count, assigned-user count |
| `users` | User profiles with enabled / stale / never-logged-in flags |
| `permission-groups` | Permission groups and whether each is custom or built-in |

Narrowing the scope skips the other API calls entirely.

### Output formats

| Format | Use when |
|---|---|
| `summary-and-findings` *(default)* | Normal use — counts plus the rows worth acting on |
| `summary-only` | You just want the counts |
| `full-detail` | You're exporting every role and user |

### The other two inputs

| Input | Default | Notes |
|---|---|---|
| `redact_usernames` | `false` | Usernames are email addresses. Turn on before sharing output. |
| `stale_login_days` | `90` | Days since last login before a user counts as stale. |

## Where the results appear

1. **Run summary page** — counts and findings tables
2. **Job log** — full JSON under the results step
3. **Artifact** — `access-audit.json`, downloadable and diffable between runs

## Reading the output

- **`summary`** — counts only, no usernames, safe to paste anywhere.
- **`findings`** — the review queue. Contains usernames unless `redact_usernames` was set.
- `null` — category outside scope, never read. `[]` — read and genuinely empty.

### What counts as a finding

| Finding | Meaning |
|---|---|
| `unassigned_roles` | A role no user holds. |
| `never_logged_in` | Account exists, never used (`last_login_ts = -1`). |
| `stale_users` | Last login older than `stale_login_days`. |
| `disabled_users` | Disabled but still present. |
| `users_without_roles` | Can sign in but holds no role. |

`never_logged_in` and `stale` are mutually exclusive — never-logged-in is tested first and excluded from stale.

```json
{
  "roles":             { "total": 166, "unassigned": 72 },
  "users":             { "total": 845, "never_logged_in": 234, "stale": 452 },
  "permission_groups": { "total": 62,  "custom": 50 }
}
```

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
| Usernames appear in the artifact | Expected unless `redact_usernames` was on. |
| Stale count looks too high | Raise `stale_login_days`. |

## More detail

Module internals and full output shape: [`terraform/modules/access-audit/README.md`](../../../terraform/modules/access-audit/README.md)

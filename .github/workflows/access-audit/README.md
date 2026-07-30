# Workflow 4 — Access Audit (read-only)

**Workflow file:** [`../access-audit.yml`](../access-audit.yml) · **Actions name:** `4. Access Audit (read-only)`

Answers "who has access to this tenant, and how" — roles, user profiles, and
permission groups, plus the subset of rows an access review actually acts on.

**Can it change the tenant?** No — and it structurally cannot.

---

## Why "cannot" rather than "does not"

Terraform can only change things declared as a `resource`. The
[`access-audit`](../../../terraform/modules/access-audit/README.md) module
contains **only `data` blocks — zero `resource` blocks**:

```bash
$ grep -rc "^resource" terraform/modules/access-audit/*.tf
0        # ← nothing to create, update or delete
```

So there is no apply job, no approval gate, and nothing to review. Run it as
often as you like.

---

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

Narrowing the scope genuinely **skips** the other API calls — it isn't just
output filtering.

### Output formats

| Format | Use when |
|---|---|
| `summary-and-findings` *(default)* | Normal use — counts plus the rows worth acting on |
| `summary-only` | You just want the counts |
| `full-detail` | You're exporting every role and user |

### The other two inputs

| Input | Default | Notes |
|---|---|---|
| `redact_usernames` | `false` | Usernames are email addresses. Leave off for an internal review; turn **on** before sharing the output anywhere. |
| `stale_login_days` | `90` | Days since last login before a user counts as stale. |

## Where the results appear

1. **Run summary page** — counts and findings tables, visible without opening the log
2. **Job log** — full JSON under the results step
3. **Artifact** — `access-audit.json`, downloadable and diffable between runs

## Reading the output

### Summary vs findings

- **`summary`** is counts only. It contains no usernames, so it is safe to paste
  anywhere.
- **`findings`** is the review queue — the rows a human should look at. It
  contains usernames unless you enabled `redact_usernames`.

The split exists because a reviewer should not have to scan 845 users to find
the 234 that matter.

### `null` vs `[]` matters

- `null` — the category was **outside your scope** (never looked at)
- `[]` — the category **was read** and is genuinely empty

### What counts as a finding

| Finding | Meaning |
|---|---|
| `unassigned_roles` | A role no user holds. Usually left over from a reorg. |
| `never_logged_in` | The account exists but has never been used. |
| `stale_users` | Last login is older than `stale_login_days`. |
| `disabled_users` | Disabled but still present. |
| `users_without_roles` | Can sign in but holds no role. |

**"Never logged in" and "stale" are deliberately separate.** In the API a
never-used account has `last_login_ts = -1`, which is "older than" every
possible cutoff. Treated naively it would be counted twice and inflate the stale
number. It is classified as never-logged-in only.

Example counts from a real run of this tenant:

```json
{
  "roles":             { "total": 166, "unassigned": 72 },
  "users":             { "total": 845, "never_logged_in": 234, "stale": 452 },
  "permission_groups": { "total": 62,  "custom": 50 }
}
```

A large `never_logged_in` count is normal on a tenant that provisions users in
bulk. It is worth reviewing rather than alarming.

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
| Usernames appear in the artifact | Expected unless `redact_usernames` was on. Re-run with it enabled before sharing. |
| Stale count looks too high | Lower-bound it by raising `stale_login_days`; the default of 90 is aggressive for a tenant with many service accounts. |

## More detail

Module internals and the full output shape:
[`terraform/modules/access-audit/README.md`](../../../terraform/modules/access-audit/README.md)

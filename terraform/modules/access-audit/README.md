# access-audit

Reads a Prisma Cloud tenant's access-control objects — roles, user profiles, and
permission groups — and derives the subset of rows an access review acts on.

**This module is read-only by construction.** It contains only `data` blocks:

```bash
$ grep -rc "^resource" terraform/modules/access-audit/*.tf
main.tf:0
outputs.tf:0
variables.tf:0
versions.tf:0
```

Terraform can only create, modify or delete things declared as a `resource`.
There are none, so a plan against this module always reports **0 to add, 0 to
change, 0 to destroy**. That is a structural guarantee, not a convention.

## Requirements

| Requirement | Version |
|---|---|
| Terraform | `~> 1.13` |
| `PaloAltoNetworks/prismacloud` | `1.7.1` |

## Usage

```hcl
module "access_audit" {
  source = "./modules/access-audit"

  enabled          = true
  scope            = "all"    # all | roles | users | permission-groups
  redact_usernames = false    # true anywhere output could be published
  stale_login_days = 90
}
```

Normally you drive it through
[Workflow 4](../../../.github/workflows/access-audit/README.md) rather than
calling it directly.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `enabled` | `bool` | `false` | Read the tenant's access-control objects. Off by default so the module costs nothing in workflows that don't need it. |
| `scope` | `string` | `"all"` | `all` \| `roles` \| `users` \| `permission-groups`. Out-of-scope categories are never fetched. |
| `redact_usernames` | `bool` | `false` | Replace each username/display name with a stable SHA-256 prefix. |
| `stale_login_days` | `number` | `90` | Days since last login before a user is reported stale. Must be >= 1. |

## Outputs

| Name | Contains usernames? | Description |
|---|---|---|
| `summary` | No | Counts only — safe to print anywhere. |
| `findings` | Yes* | The review queue: unassigned roles, never-logged-in / stale / disabled users, users with no roles. |
| `roles` | No | Every role with type, account-group count, assigned-user count. |
| `users` | Yes* | Every profile with enabled / stale / never-logged-in flags and role count. |
| `permission_groups` | No | Every permission group with its type and custom flag. |

\* honors `redact_usernames`.

## Design notes

### `null` vs `[]`

Every output distinguishes the two:

- `null` — the category was **out of scope** and was never read
- `[]` — the category **was read** and is genuinely empty

Collapsing these would make "I didn't look" indistinguishable from "there are
none," which is exactly the wrong answer to give an auditor.

Scope narrowing genuinely skips the API call (via `count` on the data source);
it is not output filtering.

### `last_login_ts` is milliseconds, and `-1` means never

Verified against the live tenant: the values range from `-1` to ~`1.78e12`, and
234 profiles sit at `-1`.

`-1` is why the stale check cannot be a naive "older than the cutoff." `-1` is
older than *every* cutoff, so a user who never logged in would be counted both
as stale and as never-logged-in, inflating the stale number. Never-logged-in is
therefore tested first and excluded from stale.

### Time comes from `plantimestamp()`, not `time_static`

The stale cutoff is:

```hcl
stale_cutoff_rfc3339 = timeadd(plantimestamp(), "-${var.stale_login_days * 24}h")
```

`plantimestamp()` is a **pure function**, evaluated once per plan.
`time_static` would have been the obvious alternative, but it is a **resource** —
using it would have put a resource in a module whose entire value proposition is
having none, and it would persist in state. Comparison uses `timecmp()` on
RFC3339 strings, which is exact and avoids hand-rolled epoch arithmetic.

### Redaction is hashing, not encoding

```hcl
username = local.redact ? substr(sha256(u.username), 0, 12) : u.username
```

Usernames are email addresses. SHA-256 is one-way and stable, so a redacted user
is still trackable across runs — you can see that *a* user changed without
learning who. Base64 or similar would be reversible and would not be redaction
at all.

This is also what makes the module safe to feed into
[drift detection](../../../.github/workflows/drift-detection/README.md), whose
output is committed to a public repo.

## Verified against the live tenant

| Category | Total | Notable |
|---|---|---|
| Roles | 166 | 72 unassigned |
| User profiles | 845 | 234 never logged in, 452 stale at 90 days |
| Permission groups | 62 | 50 custom |

Redaction was checked by grepping a full redacted run for email addresses: zero
matches.

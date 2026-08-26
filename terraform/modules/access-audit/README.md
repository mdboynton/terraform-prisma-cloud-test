# access-audit

Reads a Prisma Cloud tenant's roles, user profiles, and permission groups; derives the subset of rows an access review acts on.

Read-only: `data` blocks only, no `resource` blocks. Plan always reports 0 to add, 0 to change, 0 to destroy.

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

Normally driven through [Workflow 4](../../../.github/workflows/access-audit/README.md).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `enabled` | `bool` | `false` | Read the tenant's access-control objects. |
| `scope` | `string` | `"all"` | `all` \| `roles` \| `users` \| `permission-groups`. Out-of-scope categories are never fetched. |
| `redact_usernames` | `bool` | `false` | Replace each username with a stable SHA-256 prefix. |
| `stale_login_days` | `number` | `90` | Days since last login before a user is reported stale. Must be >= 1. |

## Outputs

| Name | Contains usernames? | Description |
|---|---|---|
| `summary` | No | Counts only. |
| `findings` | Yes* | Unassigned roles, never-logged-in / stale / disabled users, users with no roles. |
| `roles` | No | Every role with type, account-group count, assigned-user count. |
| `users` | Yes* | Every profile with enabled / stale / never-logged-in flags and role count. |
| `permission_groups` | No | Every permission group with its type and custom flag. |

\* honors `redact_usernames`.

## Notes

- `null` = out of scope, never read. `[]` = read and genuinely empty.
- `last_login_ts` is milliseconds; `-1` = never logged in. Tested before the stale check so a never-logged-in user isn't double-counted as stale.
- Stale cutoff: `timeadd(plantimestamp(), "-${var.stale_login_days * 24}h")`, compared with `timecmp()`.
- Redaction: `substr(sha256(u.username), 0, 12)` — one-way but stable across runs. Feeds [drift detection](../../../.github/workflows/drift-detection/README.md), whose output is committed to a public repo.

## Verified against the live tenant

| Category | Total | Notable |
|---|---|---|
| Roles | 166 | 72 unassigned |
| User profiles | 845 | 234 never logged in, 452 stale at 90 days |
| Permission groups | 62 | 50 custom |

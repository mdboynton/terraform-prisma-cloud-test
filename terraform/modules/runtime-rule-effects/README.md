# runtime-rule-effects

Reports the current enforcement effect of runtime rules producing alerts, and — behind a deliberate gate — raises one from `alert` to `prevent`/`block`.

Answers what workflow 8 cannot: of the rules that keep firing, which are still only watching?

**The only module in this repository that changes enforcement on a live runtime security policy.** Reading is unconditional; writing needs two separate deliberate acts and never happens during `terraform plan`.

## An escalation targets a SITE, not a rule

A container runtime rule carries 27 independent effect sites, a host rule 19 — no single `effect` field to flip.

> Corrected 2026-08-18: site list previously used key names matching `Effect$` + six hardcoded paths, hiding 2490 container and 1313 host settings at `alert`/`disable`. Sites are now found by VALUE.

| field | meaning |
|---|---|
| `kind` | `container` or `host` |
| `rule` | exact rule name |
| `site` | literal jq path, e.g. `processes.deniedList.effect` |
| `effect` | `prevent` or `block` |

`site` is copied verbatim from `alerting_sites` — nothing inferred or fuzzy-matched.

## Why this reads BOTH APIs

The CSPM alert carries no `effect` field at any depth (100 alerts verified). Enforcement state exists only in Compute Console policy objects. Requires the alert stream (CSPM) joined to rule state (Compute) by rule name.

## The effect vocabulary differs by workload type

`block` is container-only. Host rule refused at plan time:
```
`block` is not a valid effect for a host rule - use `prevent`.
```

## `disable` is excluded on purpose

Fourth effect value, undocumented, most common in practice (611 of 805 container values). Means detection is off — `disable → prevent` would switch on a detection that never ran. Reported in `disabled_sites`, never an escalation candidate; writer refuses it.

## Escalation does NOT silence workflow 8

Effect and logging are orthogonal. A blocked action still records an incident. A rule reappearing in the digest after escalation is working, not broken.

## Requirements

- `terraform` >= 1.5 (`check` blocks)
- `jq`, `curl` on the runner
- Credentials with read access to CSPM alerts + Compute Console, write access to runtime policies for escalating

## Usage

Read-only (default — writes nothing):

```hcl
module "runtime_rule_effects" {
  source = "./modules/runtime-rule-effects"

  enabled      = true
  window_days  = 14
  alert_status = "open"

  cspm_url    = var.prisma_cloud_api_url
  compute_url = var.prisma_compute_console_url
  access_key  = var.prisma_cloud_access_key
  secret_key  = var.prisma_cloud_secret_key
}
```

Escalating one site — both `escalations` and `apply_escalations` required:

```hcl
  escalations = [{
    kind   = "container"
    rule   = "my-runtime-rule"
    site   = "processes.deniedList.effect"
    effect = "prevent"
  }]

  apply_escalations = "APPLY"
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `false` | Read the tenant at all. |
| `window_days` | number | `14` | Lookback for promoted alerts (1–3650). |
| `alert_status` | string | `"open"` | `open` \| `resolved` \| `dismissed` \| `snoozed`. |
| `max_alerts` | number | `2000` | Cap on alerts fetched before grouping (1–10000). |
| `escalations` | list(object) | `[]` | `{kind, rule, site, effect}`. Empty writes nothing. |
| `apply_escalations` | string | `""` | Must be exactly `"APPLY"` to permit a write. |
| `cspm_url` | string | `null` | CSPM API host. |
| `compute_url` | string | `null` | Compute Console URL — must include the path prefix. |
| `access_key` | string | `null` | Shared across both APIs. |
| `secret_key` | string | `null` | Shared across both APIs. |
| `skip_cert_verification` | bool | `false` | Self-signed on-prem consoles only. |

## Outputs

| Name | Description |
|---|---|
| `status` | `ok` \| `disabled` \| `missing_credentials` \| `ambiguous_rules` \| `unmatched_rules` |
| `status_detail` | Human-readable explanation. Null when ok. |
| `summary` | Counts for the run. |
| `rules` | Every firing rule with match status and site inventory. |
| `sites` | One row per effect site on every matched rule. |
| `alerting_sites` | The escalation candidate list. |
| `enforced_sites` | Already at prevent/block and still firing — expected. |
| `disabled_sites` | Detection off. Not escalation candidates. |
| `ambiguous_rules` | Name exists in both policies. |
| `unmatched_rules` | Firing name with no live rule. |
| `builtin_rules` | Alerts attributed to `default`. |
| `scope` | What was actually queried. |
| `escalation_status` | `disabled` \| `nothing_requested` \| `not_confirmed` \| `will_apply` |
| `escalation_detail` | Human-readable explanation. |
| `planned_escalations` | Exactly what an apply would write. |

### Callers must branch on `status`, not the exit code

`check` blocks warn but don't fail the plan, and `terraform show -json` omits the `checks` array entirely — `status`/`escalation_status` exist because of this.

## The write path

- **`terraform plan` never writes** — escalation runs in a `null_resource` provisioner, not a `data` source. Verified: with an escalation staged and confirmed, a plan reports one resource to create and changes nothing else.
- **Two independent conditions**, neither defaulted to do anything: `escalations` non-empty (never auto-derived from `alerting_sites`), and `apply_escalations` exactly `"APPLY"` (a word, not a boolean — `true`/`yes`/`apply` all leave it read-only).
- **Credentials not in `triggers`** — trigger values persist in state; access key/secret pass through the provisioner `environment` instead. Trigger holds a sha256 of the requests only.
- **Script re-checks everything**: `confirm` must be exactly `APPLY`; `block` on host refused; `disable` refused; empty rule/site refused; validation runs before any network call; batch is all-or-nothing.
- **Re-derived from live state** — writer GETs the policy fresh, applies via `setpath` on the literal jq path, errors if rule missing/ambiguous/site absent. Never replays a stale plan.
- **Idempotency uses deep equality, not `cmp`** — raw server response vs. jq re-serialization differ in whitespace even unchanged, so byte comparison would always report "changed". jq deep comparison ignores key order, respects array order. Verified both directions (identity, key reorder, revert = unchanged; effect flip, appended rule = changed).

## Guards

- **Ambiguous rule names** — a name can exist in both container and host policies; the alert doesn't say which fired. Sites reported per kind; escalation must name the policy explicitly.
- **Rules that no longer exist** — a firing name with no live rule goes to `unmatched_rules` rather than being dropped.
- **The built-in `default` model** — both the built-in label and, in some tenants, a real rule name; separated into `builtin_rules`. Has no rule object, cannot be escalated.

## Credentials never touch `argv`

Everything passed on stdin as JSON.

## Verified against the live tenant

- CSPM alert carries no `effect` field at any depth (100 alerts)
- `block` is container-only; host rule rejects it
- `disable` is a fourth, undocumented value — 611 of 805 container values
- container rule has 27 effect sites; host rule 19, a different set
- rule names resolve across both APIs, but are not unique
- only `APPLY` arms the write; `""`, `true`, `yes`, `apply` do not
- `-target=module.runtime_rule_effects` isolates an apply to exactly 1 resource (without it, a confirmed run planned 4)

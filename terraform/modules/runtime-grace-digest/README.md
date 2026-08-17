# runtime-grace-digest

Reports **which runtime rules are still producing incidents**, grouped by rule,
workload scope (container or host) and cloud account, ordered by occurrences.

Read-only: the module contains only `data` blocks, no `resource` blocks.

This is the report-only stage of the policy-escalation pipeline. It establishes
a baseline so a human can decide whether a rule is worth escalating to
Prevent/Block. It sends nothing and changes nothing.

## The headline: this reports recurrence, not age

The original ask was *"escalate a rule if a finding goes unresolved for 14
days"*. That is the right shape for a **vulnerability** — a CVE is a state, it
is present until patched, so age is meaningful.

A **runtime incident is an event**. It happened at a point in time, and no API
call makes it un-happen. There is no "resolved" state to age against and
incidents never expire from the store. Measured against the reference tenant:

| Query | Result |
|---|---|
| Runtime incidents total | 14,410 |
| Older than 14 days | 14,398 |

So "older than N days" selects essentially everything ever recorded. Worse, the
only field that changes on a Compute incident is `acknowledged` — so an
age-based digest does not measure whether a problem was *fixed*, it measures
whether somebody clicked a button.

**"Still firing in the last N days" is the answerable question.** It is
defensible for an event-based finding, and it clears itself: a workload that
gets fixed stops producing incidents, so the rule drops off the report without
anyone updating a ticket.

## Why this reads CSPM, not the Compute Console

Runtime incidents are promoted into the CSPM alert stream as alerts with
`policyType: workload_incident`. The promoted copy is strictly better than the
raw Compute incident for this purpose:

| | Compute incident | Promoted CSPM alert |
|---|---|---|
| Runtime rule name | `audits[].ruleName` (nested, needs a second call) | `metadata.auditRuleName` |
| Occurrence count | not present | `metadata.auditCount` |
| Lifecycle | `acknowledged` only | open / dismissed / snoozed / resolved |
| Dismissal attribution | none | `dismissedBy`, `dismissalNote`, `dismissalUntilTs` |
| Time filtering | epoch ms params | relative time units |

One API, one auth path, and the lifecycle needed for a later escalation
decision. The module therefore takes **CSPM** credentials (`cspm_url`,
`access_key`, `secret_key`) — the same host as `alert-summary`, *not* the
Compute Console.

> **`metadata.auditRuleName`, not `ruleName`.** CSPM renames the field and
> nests it under `metadata` during promotion. Searching for Compute's field
> name at the top level finds nothing and makes it look like the rule name was
> lost in translation. It is not.

## Requirements

| | |
|---|---|
| Terraform | `~> 1.13` |
| Providers | `hashicorp/external ~> 2.3` |
| Binaries on PATH | `bash`, `curl`, `jq` |

## Usage

```hcl
module "runtime_grace_digest" {
  source = "./modules/runtime-grace-digest"

  enabled = true

  window_days  = 14      # recurrence window
  alert_status = "open"
  max_alerts   = 2000

  cspm_url   = var.prisma_cloud_api_url
  access_key = var.prisma_cloud_access_key
  secret_key = var.prisma_cloud_secret_key
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `false` | Off by default, so the module costs nothing in workflows that don't need it. |
| `window_days` | number | `14` | Recurrence window, 1–3650. A rule with an incident inside it is "still firing". |
| `alert_status` | string | `"open"` | One of `open`, `resolved`, `dismissed`, `snoozed`. |
| `max_alerts` | number | `2000` | Cap on alerts fetched for grouping, 1–10000. Does **not** cap the totals. |
| `cspm_url` | string | `null` | CSPM API host, e.g. `api2.prismacloud.io`. Required when enabled. |
| `access_key` | string | `null` | Access key id. Sensitive. |
| `secret_key` | string | `null` | Secret key. Sensitive. |

## Outputs

| Name | Description |
|---|---|
| `status` | `ok` \| `disabled` \| `missing_credentials` \| `suspect_unfiltered` \| `partial_grouping`. **Branch on this.** |
| `status_detail` | Human-readable explanation. Null when `ok`. |
| `summary` | Counts for the window plus the all-time total. Null when nothing was queried. |
| `rules` | Groups, ordered by occurrences. Excludes the built-in `default` model. |
| `actionable_rules` | Same as `rules` — the list a human acts on. |
| `top_rule` | Highest-occurrence rule, or null. Convenience for a one-line notification. |
| `alerts_in_window` | Server-side total for the window. Never capped by `max_alerts`. |
| `distinct_rules` | How many distinct rules fired. |
| `scope` | What was actually queried, for troubleshooting. |

**Null means "not asked".** Zero means "asked, nothing firing". Collapsing the
two would let a misconfiguration read as a clean bill of health, which for a
security report is the worst available failure mode.

## Callers must branch on `status`, not the exit code

The `check` blocks emit warnings, and **a failing check does not fail the
plan**. Worse, `terraform show -json` omits the `checks` array entirely for a
plan file, so a caller cannot detect the warning programmatically at all — it
appears only in human-readable stderr. Both behaviours verified against the
live tenant.

`status` exists so a workflow has something machine-readable to test.

## Grouping key: rule + scope + account

`scope` is derived from **`policy.name`**, not from `metadata.auditType`.

`auditType` is the audit *kind* — Filesystem, Network, Processes — and says
nothing about which runtime policy owns the rule. The container-vs-host split
lives only in `policy.name`:

- `Container workloads detected with Runtime Incidents`
- `Host workloads detected with Runtime Incidents`

This matters because **the same rule name can exist in both policies**
(`OT-WildFire-Demo-Rule` is a real example in the reference tenant). Grouping
on the name alone merges two distinct rules into one row and would point a
later escalation at the wrong policy.

`.collections` is deliberately **not** used as a routing key: it lists every
collection the resource matches — averaging 168 entries — so routing on it
would notify everyone.

## Guards

Three failure modes are specific to this API and each has a guard.

### 1. An unknown filter name returns the whole tenant

The alerts API accepts a filter it does not recognise, returns HTTP 200, and
ignores it. A typo in a filter *name* yields **18,351,682** rows — the entire
tenant — rather than an error. (An unknown filter *value* fails closed and
returns 0, which is the safe direction.)

The guard: query the window and an all-time baseline, and compare. If a short
window returns exactly the all-time count, `status` becomes
`suspect_unfiltered`.

The window has to be genuinely short for equality to be suspicious — a long
window legitimately covers every alert the tenant has. Caught in testing: a
3000-day window returned all 111 alerts and was wrongly flagged. The threshold
is now 90 days.

### 2. `limit` is a cap, not a page size

When the cap is hit the remainder is simply absent — no error, no marker. The
grouped table would silently become a sample.

The guard: compare the server-side window total against the number actually
fetched. If they differ, `complete` is false and `status` becomes
`partial_grouping`.

This matters more than it first appears: rules below the cut-off are missing
**entirely**, not merely undercounted. A rule absent from a partial table may
still be firing. `distinct_rules` and `occurrences` are sample-derived in this
state; only `alerts_in_window` and `alerts_all_time` remain server-side totals.

### 3. `detailed=true` is required for `totalRows`

Without it the field is `0` — which looks exactly like "no alerts".

## The built-in `default` model

Some alerts carry `auditRuleName: "default"`. That is not one of the named
runtime rules; it appears to be the built-in learned model. It cannot be
escalated by name, so it is excluded from `rules` and counted separately in
`unnamed_rule_alerts`. Reporting it as an actionable row would send someone
looking for a rule that does not exist in the console.

## Credentials never touch `argv`

Anything on a command line is visible in `ps` to every user on the host. The
script passes the auth body on **stdin** (`curl --data @-`) and the token via
`-H @file` from a `0700` temp directory, removed on exit. Verified: 0 of 32
sampled `argv` snapshots during a live run contained credential material.

## Verified against the live tenant

- `status=ok`, `disabled`, `missing_credentials` and `partial_grouping` all
  produce the documented values
- **0 `resource_changes`** on a targeted plan, and 0 attributable to this
  module on an untargeted one
- Relative windows narrow correctly: 7d→0, 14d→1, 30d→8, 90d→38, all→341
- Promotion is one-to-one, not aggregation: `auditCount` was 1 on 99 of 100
  sampled alerts (max 2, sum 101)

## A note on the reference tenant

Findings above describe **API mechanics** — field names, filter behaviour,
pagination, failure modes. Those are properties of the product.

Counts and rule names come from a **sandbox** tenant and are illustrative only.
Nothing here infers customer behaviour from what happens to be sitting in a lab.

# runtime-grace-digest

Reports which runtime rules are still producing promoted CSPM alerts, grouped by rule, workload scope (container/host), and cloud account, ordered by occurrences.

Read-only: `data` blocks only, no `resource` blocks.

> **"Incident" vs "alert".** Incident = raw runtime event, Compute API only. Alert = what CSPM creates when it promotes that incident (`policyType: workload_incident`). This module reads alerts — POSTs to CSPM `/v2/alert`, never contacts the Compute Console.

Report-only stage of the policy-escalation pipeline. Sends nothing, changes nothing.

## Reports recurrence, not age

A runtime incident is an event, not a state — no "resolved" to age against, incidents never expire. Measured: 14,410 total incidents, 14,398 older than 14 days. "Still firing in the last N days" is the answerable question — clears itself when the workload is fixed.

## Why this reads CSPM, not the Compute Console

Runtime incidents are promoted into the CSPM alert stream (`policyType: workload_incident`):

| | Compute incident | Promoted CSPM alert |
|---|---|---|
| Runtime rule name | `audits[].ruleName` (nested, second call) | `metadata.auditRuleName` |
| Occurrence count | not present | `metadata.auditCount` |
| Lifecycle | `acknowledged` only | open / dismissed / snoozed / resolved |
| Dismissal attribution | none | `dismissedBy`, `dismissalNote`, `dismissalUntilTs` |
| Time filtering | epoch ms params | relative time units |

Takes CSPM credentials (`cspm_url`, `access_key`, `secret_key`) — same host as `alert-summary`, not the Compute Console.

> Field is `metadata.auditRuleName`, not `ruleName` — CSPM renames and nests it under `metadata` during promotion.

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
| `enabled` | bool | `false` | Read the tenant. |
| `window_days` | number | `14` | Recurrence window, 1–3650. Can legitimately return zero — see "Two windows that must agree". |
| `alert_status` | string | `"open"` | `open` \| `resolved` \| `dismissed` \| `snoozed`. |
| `notify_days` | list(number) | `[1,3,5,7,10,13]` | Grace-period days that get a reminder, matched on `age_days` exactly. Every entry must be `< grace_days`. |
| `severities` | list(string) | `[]` | Restrict to alerts whose policy carries one of these severities. Empty = no filter. Lowercase only. |
| `max_alerts` | number | `2000` | Cap on alerts fetched for grouping, 1–10000. Does not cap totals. |
| `cspm_url` | string | `null` | CSPM API host. Required when enabled. |
| `access_key` | string | `null` | Sensitive. |
| `secret_key` | string | `null` | Sensitive. |
| `notify_enabled` | bool | `false` | Also plan the grace warning. Nothing sent. |
| `grace_days` | number | `14` | Days a finding may stay open before its rule is a candidate. 1–3650. |
| `campaign_start_date` | string | `null` | Required with `notify_enabled`. `YYYY-MM-DD`. Day 0 is `max(firstSeen, campaign_start_date)`. |
| `warning_recipient_override` | string | `null` | Required with `notify_enabled`. Every planned message addressed here. |

## Outputs

| Name | Description |
|---|---|
| `status` | `ok` \| `disabled` \| `missing_credentials` \| `suspect_unfiltered` \| `empty_window` \| `partial_grouping`. Branch on this. |
| `status_detail` | Human-readable explanation. Null when `ok`. |
| `summary` | Window counts plus all-time total. Null when nothing queried. |
| `rules` | Groups, ordered by occurrences. Excludes built-in `default`. |
| `actionable_rules` | Same as `rules`. |
| `top_rule` | Highest-occurrence rule, or null. |
| `alerts_in_window` | Server-side total for the window. Never capped by `max_alerts`. |
| `distinct_rules` | Count of distinct rules fired. |
| `scope` | What was actually queried. |
| `notify_status` | `ok` \| `disabled` \| `no_override` \| `no_campaign_start` \| `not_queried` \| `all_overdue` \| `has_unroutable`. Branch on this. |
| `notify_status_detail` | Human-readable explanation. Null when `ok`. |
| `warning_plan` | Counts for the planned warning. Null when planning disabled. |
| `warning_messages` | Per-rule-group plan. Contains live personal email addresses in `would_notify`. |
| `due_today_messages` | Subset of `warning_messages` due today. |
| `warning_accounts` | One entry per email, per account, with rules in `groups`. Live personal email addresses. |

`null` = not asked. `0` = asked, nothing firing.

## Two windows that must agree

This module and `runtime-rule-effects` (workflow 9) query independently configured windows with no cross-check:

| | window | open alerts returned |
|---|---|---|
| This module, default | 14 days | **0** |
| Workflow 9, as run | 1825 days | **111** |

A grace campaign on this module's defaults would plan zero warnings while workflow 9 sees 111 alerts / 8 escalatable rules. Failure is asymmetric: window too narrow → nobody warned, report looks clean; escalation proceeds anyway → workloads blocked with no notice.

Protection is `empty_window` status + `window_returned_alerts` check — both advisory (don't fail the plan). Before a campaign: set `window_days` to cover the same population workflow 9 will escalate against, confirm `status != "empty_window"`.

## Callers must branch on `status`, not the exit code

`check` blocks warn but don't fail the plan, and `terraform show -json` omits the `checks` array entirely.

## Grouping key: rule + scope + account

`scope` is derived from `policy.name` (`Container workloads detected with Runtime Incidents` / `Host ...`), not `metadata.auditType` (which is the audit kind — Filesystem, Network, Processes — and doesn't say which policy owns the rule).

Same rule name can exist in both policies (`OT-WildFire-Demo-Rule`, live example) — grouping on name alone merges two distinct rules and misdirects escalation.

`.collections` is not used as a routing key — averages 168 entries per resource, would notify everyone.

## Guards

### 1. An unknown filter name returns the whole tenant

A typo in a filter name yields 18,351,682 rows (the entire tenant) rather than an error. An unknown filter *value* usually fails closed (0 rows) — except `policy.severity` (guard 4).

Guard: compare window vs. all-time count; equality flags `suspect_unfiltered`. Threshold is 90 days (a genuinely long window legitimately matches all-time — a 3000-day window was wrongly flagged before this fix).

### 2. `limit` is a cap, not a page size

Remainder is silently absent past the cap — no error, no marker. Guard: compare server-side window total against fetched count; mismatch sets `complete = false`, `status = partial_grouping`. Rules below the cutoff are missing entirely, not undercounted — `distinct_rules`/`occurrences` become sample-derived; `alerts_in_window`/`alerts_all_time` stay server-side totals.

### 3. `detailed=true` is required for `totalRows`

Without it the field is `0`, indistinguishable from "no alerts".

### 4. ⚠️ `policy.severity` fails OPEN

| request | severities returned | verdict |
|---|---|---|
| one object, `value: "high"` | `["high"]` | filters |
| two objects, `"high"` + `"critical"` | `["critical","high"]` | OR — correct multi-value form |
| one object, `value: "high,critical"` | all five | silently ignored |
| one object, `value: "nonsense"` | all five | silently ignored |

Multi-value means repeating the object, not comma-joining. A typo widens the query instead of emptying it — `"High"` with a capital H is enough.

Threefold guard: Terraform validation (lowercase set, plan time, module + root) → `digest.sh` re-validates → post-fetch assertion checks every returned alert's severity is in the requested set (the one that catches the filter being dropped for any reason). `severities_verified` on `scope` is true only when a filter was requested, rows came back, and all were in-set — row count alone is never evidence the filter applied.

## One email per ACCOUNT, not per rule

`cloudAccountOwners` is a property of the cloud account, not the rule — sending per rule group repeats the same people.

| | per rule group | per account |
|---|---|---|
| `twistlock-cto-lab` (3 rules, 5 owners) | 15 sends | **5** |
| whole tenant | 26 sends | **9** |

Safe because owners are constant within an account (all 11 accounts: one distinct owner set across groups) — union widens rather than drops if that ever changes.

`warning_accounts` is the send unit; `warning_messages` stays the per-rule-group view.

Deliberately not done: grouping by person (one address owning two accounts would blur which finding belongs where), dropping unroutable accounts (flagged `routable: false` and counted in `accounts_unroutable` instead — filtering them is how a workload gets escalated with nobody warned).

## The reminder schedule

`notify_days` = exact grace-period days matched against `age_days` (default 1, 3, 5, 7, 10, 13 of 14), not a "remind every N days" rule — plan is a pure function of age, no state carried between runs.

A missed scheduled run is a missed notice (no send ledger exists yet) — schedule density (max 3 days between contacts) is the safety margin.

- `notify_today` is independent of `routable` — an unowned group is still reported due; `due_today` vs `due_today_routable` shows the gap.
- Clock is GRACE age, not finding age — a 365-day-old finding in a campaign announced 3 days ago is on grace day 3.

Every `notify_days` entry must be `< grace_days` — `[1,7,14]` with 14-day grace is rejected (a reminder on the deadline would never fire).

### ⚠️ The date is interpreted in UTC

`campaign_start_date` converts at UTC midnight. West of Greenwich, local "today" is often already tomorrow in UTC — shifts every reminder day. Use `date -u +%F`.

## Severity is a pass-through filter

Empty list = no filter, reported as "all severities" explicitly. On the reference tenant this changes nothing — `policy.severity` present on 111/111 open runtime alerts, all `high` (only two built-in promoting policies, both hardcode `high`).

Implemented for tenants with custom promoting policies, and so a scoped campaign states its filter in the query rather than a comment.

Severity belongs to the promoting policy, not the runtime incident — the Compute incident itself has no severity, only `incidentCategory` (Suspicious Binary, Crypto Miner, Lateral Movement, etc.) and `auditRuleName`.

## The built-in `default` model

Alerts with `auditRuleName: "default"` are the built-in learned model, not a named rule — can't be escalated by name. Excluded from `rules`, counted in `unnamed_rule_alerts`.

## Credentials never touch `argv`

Auth body via stdin (`curl --data @-`); token via `-H @file` from a `0700` temp dir removed on exit. Verified: 0 of 32 sampled `argv` snapshots contained credential material.

## The grace warning (plan only)

`notify_enabled = true` computes who would be told a rule is heading for escalation.

This module cannot send anything — no SMTP client, no webhook, `notify_plan.sh` only writes JSON to stdout. The workflow's separate gated `send` job does the mailing — see [the workflow README](../../../.github/workflows/runtime-grace-digest/README.md).

### When the clock starts

Day 0 = `max(firstSeen, campaign_start_date)`, not finding age. Counting from `firstSeen` alone was rejected — every one of 52 open findings was already older than 14 days (min 29, median 150, max 371 days); the first run would tell all 25 groups their grace had already expired.

- `finding_age_days` — true age, unaffected by campaign date.
- `backlog` — true when the announcement (not the finding) set day 0.

No stored state — `firstSeen` recomputed from the API every run (present on 100/100 sampled alerts).

A group anchors on its OLDEST open finding (`min`, not `max`) — `rp-lab` fires sporadically across 7 months/8 accounts; anchoring on newest would mean it never becomes overdue.

A future `campaign_start_date` is rejected by a check (would make every countdown negative).

### Why the override recipient is required, not a "dry run" flag

`warning_recipient_override` has no default; planning refuses without it. Real addresses travel as `would_notify` for review, never as a recipient. A required field that replaces the address means the unreviewed path doesn't exist — removing it is a code change, not config.

`cloudAccountOwners` holds live mailboxes of real people, including external addresses — a sent email can't be recalled, unlike every other module's tenant-scoped (sandbox) blast radius.

### Recipients come from the alert, and only sometimes

| Signal | Coverage |
|---|---|
| `resource.cloudAccountOwners[]` | 32 / 52 |
| `resource.additionalInfo.clusters[]` | 40 / 52 |
| `resource.account` | 52 / 52 |
| neither owner nor cluster | 10 / 52 |

⚠️ Not the same as the image API — `/api/v1/images` has no owner label (0 of 300 sampled); the promoted CSPM alert does.

⚠️ `cloudAccountOwners` is the cloud account owner, not the workload owner — one shared lab account produced 15 of 52 open alerts, one rule group addressed 5 people about workloads that may not be theirs.

### Outputs

| Output | Meaning |
|---|---|
| `notify_status` | `ok` \| `disabled` \| `no_override` \| `no_campaign_start` \| `not_queried` \| `all_overdue` \| `has_unroutable` |
| `warning_plan` | counts: planned, overdue, unroutable, not_escalatable, sendable, distinct_owners, max_recipients |
| `warning_messages` | per group: `age_days`, `days_remaining`, `overdue`, `escalatable`, `routable`, `would_notify`, `recipient` |

`sendable` = overdue AND addressable AND escalatable.

### Two things settled before anything is sent

1. Clock starts at the alert (`alertTime`), so a backlog looks already-expired without a campaign start date — every reference-tenant candidate was already past 14 days (oldest by 368). A grace period must start when announced.
2. Groups with no owner are reported, never dropped — need a declared fallback recipient. Groups pointing at the built-in `default` model are flagged `escalatable: false`.

### The artifact holds personal data

`warning_messages[].would_notify` has real addresses. Job summary prints counts only; addresses stay in the run artifact. `terraform/runtime-grace-digest.json` is git-ignored.

## Verified against the live tenant

- `status=ok`, `disabled`, `missing_credentials`, `partial_grouping` all produce documented values
- 0 `resource_changes` on a targeted plan, 0 attributable on an untargeted one
- Relative windows narrow correctly: 7d→0, 14d→1, 30d→8, 90d→38, all→341
- Promotion is one-to-one: `auditCount` was 1 on 99/100 sampled alerts (max 2, sum 101)

Counts and rule names above come from a sandbox tenant, illustrative only.

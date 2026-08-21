# runtime-grace-digest

Reports **which runtime rules are still producing promoted CSPM alerts**,
grouped by rule, workload scope (container or host) and cloud account, ordered
by occurrences.

Read-only: the module contains only `data` blocks, no `resource` blocks.

> ### "Incident" vs "alert" — they are not interchangeable here
>
> **Incident** is the Compute Console's noun: the raw runtime event, reachable
> only through the Compute API. **Alert** is what CSPM creates when it promotes
> that incident, carrying `policyType: workload_incident`.
>
> **This module reads alerts.** It POSTs to CSPM `/v2/alert` and never contacts
> the Compute Console. Everything it counts, filters, groups and ages is a
> promoted alert. Where this README says "incident" it is describing the
> underlying event; where it says "alert" it means the record actually being
> queried — and the distinction decides which API, which credentials, and which
> field names apply.
>
> This document previously led with "still producing incidents", which read as
> though the Compute API was in use. It was not, and never has been.

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
| `window_days` | number | `14` | Recurrence window, 1–3650. A rule with a promoted alert inside it is "still firing". **The default is deliberately short and can legitimately return zero** — see "Two windows that must agree" below before using this for a grace campaign. |
| `alert_status` | string | `"open"` | One of `open`, `resolved`, `dismissed`, `snoozed`. |
| `notify_days` | list(number) | `[1,3,5,7,10,13]` | Which days of the grace period get a reminder, matched on `age_days` exactly. Every entry must be `< grace_days`. See "The reminder schedule". |
| `severities` | list(string) | `[]` | Restrict to alerts whose **policy** carries one of these severities. Empty = no filter. Lowercase only. See "Severity is a pass-through filter". |
| `max_alerts` | number | `2000` | Cap on alerts fetched for grouping, 1–10000. Does **not** cap the totals. |
| `cspm_url` | string | `null` | CSPM API host, e.g. `api2.prismacloud.io`. Required when enabled. |
| `access_key` | string | `null` | Access key id. Sensitive. |
| `secret_key` | string | `null` | Secret key. Sensitive. |
| `notify_enabled` | bool | `false` | Also PLAN the grace warning. Nothing is ever sent. |
| `grace_days` | number | `14` | Days a finding may stay open, counted from day 0, before its rule is a candidate. 1–3650. |
| `campaign_start_date` | string | `null` | **Required when `notify_enabled`.** `YYYY-MM-DD`. The day the campaign was announced. Day 0 is `max(firstSeen, campaign_start_date)` — see "When the clock starts". |
| `warning_recipient_override` | string | `null` | **Required when `notify_enabled`.** Every planned message is addressed here. Not a dry-run toggle — see below. |

## Outputs

| Name | Description |
|---|---|
| `status` | `ok` \| `disabled` \| `missing_credentials` \| `suspect_unfiltered` \| `empty_window` \| `partial_grouping`. **Branch on this.** |
| `status_detail` | Human-readable explanation. Null when `ok`. |
| `summary` | Counts for the window plus the all-time total. Null when nothing was queried. |
| `rules` | Groups, ordered by occurrences. Excludes the built-in `default` model. |
| `actionable_rules` | Same as `rules` — the list a human acts on. |
| `top_rule` | Highest-occurrence rule, or null. Convenience for a one-line notification. |
| `alerts_in_window` | Server-side total for the window. Never capped by `max_alerts`. |
| `distinct_rules` | How many distinct rules fired. |
| `scope` | What was actually queried, for troubleshooting. |
| `notify_status` | `ok` \| `disabled` \| `no_override` \| `no_campaign_start` \| `not_queried` \| `all_overdue` \| `has_unroutable`. **Branch on this.** |
| `notify_status_detail` | Human-readable explanation. Null when `ok`. |
| `warning_plan` | Counts for the planned warning. Null when planning is disabled. |
| `warning_messages` | Per-group plan. **Contains live personal email addresses** in `would_notify`. |

**Null means "not asked".** Zero means "asked, nothing firing". Collapsing the
two would let a misconfiguration read as a clean bill of health, which for a
security report is the worst available failure mode.

## Two windows that must agree

This module and `runtime-rule-effects` (workflow 9) query the same tenant over
**independently configured windows**. Nothing links them, and when they
disagree the result is silent and one-directional:

| | window | open alerts returned |
|---|---|---|
| This module, default | 14 days | **0** |
| Workflow 9, as run | 1825 days | **111** |

Measured on the reference tenant. A grace campaign run on this module's
defaults would plan **zero** warnings, address **nobody**, and report success —
while workflow 9 sees 111 alerts and 8 escalatable rules over the same tenant.

The failure is asymmetric and that is what makes it dangerous:

- **Window too narrow** → nobody is warned, and the report looks clean.
- **Escalation proceeds anyway** → workloads are blocked with no notice.

There is no cross-check between the two workflows, because neither can see the
other's inputs. The protection is the `empty_window` status and the
`window_returned_alerts` check, which fire when the window returns nothing
while the tenant holds alerts. **Both are advisory** — a failed check does not
fail the plan (see above), so a caller must branch on `status`.

> **Before any grace campaign:** set `window_days` here to cover the same
> population workflow 9 will escalate against, and confirm
> `status != "empty_window"`. The two numbers are a policy decision about who
> gets warned, not a tuning knob.

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

Four failure modes are specific to this API and each has a guard.

### 1. An unknown filter name returns the whole tenant

The alerts API accepts a filter it does not recognise, returns HTTP 200, and
ignores it. A typo in a filter *name* yields **18,351,682** rows — the entire
tenant — rather than an error.

An unknown filter *value* usually fails closed and returns 0, which is the safe
direction. **`policy.severity` is the exception** — see guard 4.

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

### 4. ⚠️ `policy.severity` fails OPEN

Unlike every other filter here, a bad severity *value* does not return zero
rows. It returns **every** row. Measured live against `/v2/alert`:

| request | severities returned | verdict |
|---|---|---|
| one object, `value: "high"` | `["high"]` | ✅ filters |
| two objects, `"high"` + `"critical"` | `["critical","high"]` | ✅ OR — the correct multi-value form |
| one object, `value: "high,critical"` | all five | ❌ silently ignored |
| one object, `value: "nonsense"` | all five | ❌ silently ignored |

Two consequences, both nasty:

**Multi-value means repeating the object, not joining with commas.** The comma
form is the natural thing to write and it quietly disables the filter.

**A typo widens the query instead of emptying it.** An empty report gets
investigated; a report covering the whole tenant just looks busier than
expected. On a digest that feeds a campaign which eventually *blocks*
workloads, that is the difference between a false alarm and blocking people who
were never in scope. `"High"` with a capital H is enough to trigger it.

The guard is threefold, because no single layer is sufficient:

1. **Terraform validation** rejects any value outside the lowercase set, at
   plan time, in both the module and the root.
2. **`digest.sh` re-validates** its own input, so a direct invocation cannot
   bypass the above.
3. **A post-fetch assertion** checks every returned alert's severity is in the
   requested set, and hard-fails if not. This is the one that matters: the
   first two catch typos, but only inspecting the response catches the filter
   being dropped for any other reason.

**The row count is never evidence the filter applied.** `severities_verified`
on the `scope` output is — it is true only when a filter was requested, rows
came back, and all of them were inside the requested set.

## The reminder schedule

`notify_days` is the set of grace-period days on which a group is due a
reminder — by default 1, 3, 5, 7, 10 and 13 of a 14-day period, with the
deadline itself handled by escalation rather than another email.

It is a **set of exact days matched against `age_days`**, not a "remind every N
days" rule. That keeps the plan a pure function of the finding's age: the same
input on the same day yields the same output, and no state has to be carried
between runs.

**The cost of that is worth stating plainly: a missed run is a missed notice.**
If the scheduled run does not fire on day 3, nobody gets a day-3 reminder — the
next contact is day 5. Catching up would need a record of what was actually
sent, and `firstSeen` cannot supply it: it says when the finding appeared, not
when anyone was told. That ledger is deliberately not built yet, so the density
of the schedule is the safety margin — it never leaves more than three days
between contacts.

Two properties that are easy to get wrong, and are tested:

- **`notify_today` is independent of `routable`.** A group with no owner is
  still reported as due. Filtering those out would hide exactly the findings
  that get escalated with nobody warned. `due_today` and `due_today_routable`
  are both reported, and the difference between them is the number of people
  who will not hear from you.
- **The clock is the GRACE age, not the finding age.** A 365-day-old finding in
  a campaign announced 3 days ago is on grace day 3, so it gets the day-3
  reminder. Tracking the finding's own age would sail every backlog item past
  all six reminder days before the campaign began.

Every entry must be strictly less than `grace_days`. `[1,7,14]` with a 14-day
grace is **rejected**, not quietly accepted: a reminder on the deadline would
never fire, and silently dropping it would leave someone believing in a final
warning that does not exist.

### ⚠️ The date is interpreted in UTC

`campaign_start_date` is converted at **UTC midnight**, and "now" is UTC. West
of Greenwich, "today" locally is often already tomorrow in UTC, so a date typed
from a local calendar can land one day off and shift every reminder day with
it. This cost a confusing test result during development — the schedule looked
inverted until the dates were recomputed in UTC. Use `date -u +%F`.

## Severity is a pass-through filter

`severities` restricts the digest to alerts promoted by a policy of a given
severity. The default is an empty list, meaning **no filter** — the digest
describes every severity, and the report says "all severities" out loud so a
reader cannot mistake an unfiltered count for a scoped one.

**On the reference tenant this input changes nothing, and that is expected.**
Measured: `policy.severity` is present on 111/111 open runtime alerts and every
one of them is `high`. Only two built-in policies promote runtime incidents —
*Container workloads detected with Runtime Incidents* and its Host counterpart —
and both hardcode `high`. Asking for `high` returns 111; asking for `critical`
returns 0.

It is implemented anyway for two reasons. A tenant with custom promoting
policies will carry a real spread, and this module is meant to move between
tenants. And a campaign scoped to "high and critical only" should say so in the
query rather than in a comment — an unwritten filter is one nobody can check.

Note the layering: severity belongs to the **promoting policy**, not to the
runtime incident. The Compute incident object has no severity at all; it
carries `incidentCategory` (Suspicious Binary, Crypto Miner, Lateral Movement,
and so on). If you need to discriminate *within* the runtime population on this
tenant, that field and `auditRuleName` are what actually vary — severity does
not.

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

## The grace warning (plan only)

Set `notify_enabled = true` and the module also works out **who would be told**
that a rule is heading for escalation — how old the oldest open alert is, how
many days of grace remain, and which mailbox the message would go to.

**It cannot send anything.** There is no SMTP client, no webhook, no `mail`
command anywhere in the module. `notify_plan.sh` produces JSON on stdout and
nothing else.

### When the clock starts

Day 0 for a group is **`max(firstSeen, campaign_start_date)`**, not the age of
the finding.

The obvious design — count from each finding's own `firstSeen` — was measured
against this tenant and rejected. Every one of the 52 open findings is already
older than a 14-day grace period (min 29 days, median 150, max 371). Counting
from `firstSeen` alone means the very first run tells all 25 groups their grace
period expired before they were ever told it had begun. That is not a warning,
it is an ambush.

`campaign_start_date` fixes the announcement. Anything already open when the
campaign began starts its countdown then; anything that appears afterwards
starts from its own `firstSeen`. Two fields make this visible in the plan:

- `finding_age_days` — the true age, unaffected by the campaign date.
- `backlog` — true when the announcement, not the finding, set day 0. On a
  first run this is normally every group, and it is the count of people
  hearing about this for the first time.

There is no stored state anywhere in this. `firstSeen` is present on 100/100
sampled alerts and the API reports it identically on every read, so the
countdown is recomputed from scratch on each run. No ledger, no artifact, no
committed file to drift.

**A group is anchored on its OLDEST open finding** (`min`, not `max`). A rule
that keeps producing new alerts must not have its clock reset by each one —
`rp-lab` fires sporadically across 7 months and 8 accounts, and anchoring on
the newest finding would mean it never becomes overdue at all.

A date in the future is rejected by a check: it would make every countdown
negative, so nothing could ever be escalated and the report would look calm
indefinitely.

### Why the override recipient is required, not a "dry run" flag

`warning_recipient_override` has no default, and planning refuses to run
without it. Every planned message is addressed to that one value, and the
addresses read from the alerts travel alongside as `would_notify` — visible for
review, never used as a recipient.

A dry-run boolean can be flipped by accident. A required field that *replaces*
the address means the unreviewed path does not exist yet: removing it is a code
change, not a configuration change.

This matters more here than anywhere else in the repo. Every other module's
blast radius stops at the tenant, and the tenant is a sandbox — a wrong write
is undone by another write. `cloudAccountOwners` holds **live mailboxes of real
people, including addresses outside the company**, and a sent email cannot be
recalled.

### Recipients come from the alert, and only sometimes

Measured over the open alerts in the reference tenant:

| Signal | Coverage |
|---|---|
| `resource.cloudAccountOwners[]` | 32 / 52 |
| `resource.additionalInfo.clusters[]` | 40 / 52 |
| `resource.account` | 52 / 52 |
| **neither owner nor cluster** | **10 / 52** |

⚠️ Do not confuse this with the image API. `/api/v1/images` carries **no owner
label at all** (0 of 300 sampled). The promoted CSPM alert is a different
record and does carry one.

⚠️ `cloudAccountOwners` is the **cloud account** owner, not the workload owner.
One shared lab account produced 15 of the 52 open alerts, and a single rule
group addressed 5 people — so some recipients would get mail about workloads
that are not theirs. A declared `teams.yaml` mapping would be more precise;
that decision is open.

### Outputs

| Output | Meaning |
|---|---|
| `notify_status` | `ok` \| `disabled` \| `no_override` \| `no_campaign_start` \| `not_queried` \| `all_overdue` \| `has_unroutable` |
| `warning_plan` | counts: planned, overdue, unroutable, not_escalatable, sendable, distinct_owners, max_recipients |
| `warning_messages` | per group: `age_days`, `days_remaining`, `overdue`, `escalatable`, `routable`, `would_notify`, `recipient` |

`sendable` is the only set a send path could honestly mail: **overdue AND
addressable AND pointing at a rule escalation can act on.**

### Two things that must be settled before anything is sent

Both are reported as `check` warnings rather than being silently tolerated.

**1. The clock starts at the alert, so a backlog is already expired.** The
countdown runs from each alert's `alertTime`. On the reference tenant *every*
candidate was already past a 14-day window — the oldest by 368 days. A first
run would not warn anyone; it would announce an expiry that happened a year
ago. **A grace period has to start when it is announced.** A send path needs a
campaign start date and must measure from first contact.

**2. Some candidates cannot be warned at all.** Groups with no owner on the
alert are reported, never dropped — silently skipping them is how a workload
gets blocked with nobody warned. They need a declared fallback recipient.

Separately, groups pointing at the built-in `default` model are flagged
`escalatable: false`: no escalation can be aimed at them, so warning about them
would threaten a consequence that cannot be carried out.

### The artifact holds personal data

`warning_messages[].would_notify` contains real addresses. The workflow prints
only **counts** to the job summary — which is visible to everyone with repo
read access — and leaves the addresses in the run artifact.
`terraform/runtime-grace-digest.json` is git-ignored for the same reason.

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

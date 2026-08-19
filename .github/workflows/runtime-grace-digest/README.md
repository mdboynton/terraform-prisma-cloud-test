# Workflow 8 — Runtime Grace Digest (read-only)

Answers one question: **which runtime rules are still firing?**

It lists the rules that produced **promoted CSPM alerts** inside a recent
window, grouped by rule, workload scope (container or host) and cloud account,
ordered by how many times they fired.

> **A word on "incident" vs "alert".** An *incident* is the raw runtime event
> in the Compute Console. CSPM promotes it into an *alert*. **This workflow
> reads alerts** — it queries the CSPM alert API and never contacts the Compute
> Console. The two words describe the same underlying event but different
> records, different APIs and different credentials, so this page uses "alert"
> for the thing being counted.

It **sends nothing and changes nothing**. No email, no tickets, no enforcement.
This is the baseline-gathering stage of the escalation pipeline — the gated
workflow that proposes flipping a rule to Prevent/Block is separate and does not
exist yet.

## Why "cannot" rather than "does not"

The `runtime-grace-digest` module contains only Terraform `data` blocks — no
`resource` blocks. There is nothing for an apply to apply. That is why this
workflow has no apply job and no environment gate: the read-only property comes
from the module's construction, not from a policy someone could forget.

## It reports recurrence, not "unresolved for N days"

If you came here expecting "show me findings nobody has fixed in 14 days",
read this part.

That framing works for a **vulnerability** — a CVE is a state, it stays present
until patched, so age is meaningful. A **runtime incident is an event**. It
happened, and nothing makes it un-happen. There is no "resolved" state to age
against, and incidents never expire.

In the reference tenant, **14,398 of 14,410** runtime incidents are older than
14 days. An age-based report would list almost everything, forever, and the
only thing that would ever remove a row is somebody clicking *acknowledge* —
which records no attribution and says nothing about whether the workload was
fixed.

**"Still firing in the last N days"** is the question the data can answer. It
also clears itself: fix the workload, the incidents stop, the rule leaves the
report. Nobody has to close a ticket for the number to go down.

## How to use it

Actions → **8. Runtime Grace Digest (read-only)** → Run workflow.

| Input | Default | What it does |
|---|---|---|
| `window_days` | `14` | The recurrence window. A rule with an alert inside it counts as still firing. **A short window can return nothing while the tenant is full of alerts** — see below. |
| `alert_status` | `open` | Which lifecycle state to report. `dismissed` reviews what teams have accepted. |
| `max_alerts` | `2000` | Cap on alerts read for grouping. Totals are never capped by this. |
| `plan_warnings` | off | Also work out **who would be warned** that a rule is heading for escalation. Sends nothing. |
| `grace_days` | `14` | Days an alert may stay open before its rule becomes a candidate. Only used with `plan_warnings`. |

It also runs **automatically every Monday at 08:00 UTC** with the defaults.
`plan_warnings` is **off** on that schedule: a weekly cron does not need to
re-derive a recipient list nobody asked for.

### An empty report is not the same as a clean tenant

`window_days` decides what you can see, and the default is short. On the
reference tenant:

| window | open alerts |
|---|---|
| 14 days (the default) | **0** |
| 1825 days | **111** |

An empty result renders exactly like a healthy tenant — no rows, no warnings.
The run says `status: empty_window` when this happens, and the summary carries
a warning explaining it, precisely because the table alone cannot tell you
which of the two you are looking at.

**This matters most for a grace campaign.** Workflow 9 escalates rules over
*its own* window. If this workflow's window is narrower, it warns fewer people
than workflow 9 will block — and if it returns nothing, it warns nobody at all
while the escalation goes ahead. Nothing links the two settings; they have to
be set to agree deliberately.

## Where the results appear

- **Summary page** — the report. Start here.
- **Artifact** `runtime-grace-digest` — full JSON, 90-day retention, including
  every group when the table on the summary page is truncated to the top 40.

## The grace warning — planned, never sent

Turn on `plan_warnings` and the report gains a second section: who *would* be
told that a rule is heading for escalation, how old the oldest open alert is,
and how many of those messages could honestly be sent.

**Nothing is sent, and nothing here can send.** There is no SMTP client, no
webhook and no mail command anywhere in this workflow or the module behind it.
Every planned message is addressed to one fixed override recipient; the real
owner addresses are recorded for review only.

That is deliberate. Every other workflow in this repo can only affect the
tenant, and a wrong write is undone by another write. These recipients are
**live mailboxes of real people**, read from the alert's `cloudAccountOwners`,
and a sent email cannot be recalled. So the addressing gets reviewed first, in
a form that physically cannot contact anyone.

### Reading it

| Row | Meaning |
|---|---|
| Rule groups with an open alert | Candidates. Only `open` alerts run the clock. |
| Past the grace window | Already over the threshold. |
| No owner on the alert (unroutable) | Cannot be addressed to anyone. |
| Not escalatable (built-in model) | The `default` learned model — no escalation can target it. |
| **Could honestly be warned today** | Overdue **and** addressable **and** escalatable. |
| Distinct people who would be contacted | Fan-out, before any message is written. |
| Most recipients on a single group | How many people one rule would notify. |

Only the **counts** appear on the summary page — it is visible to everyone with
repo read access. The addresses are in the artifact.

### Two warnings you will probably see on a first run

**"Every planned warning is already past the deadline."** The countdown runs
from each alert's own `alertTime`, so against an existing backlog the deadline
passed long ago — in the reference tenant, every candidate was overdue and the
oldest by 368 days. Sending that would not be a warning; it would announce an
expiry that already happened. A grace period has to start when it is
**announced**, so a send path needs a campaign start date measured from first
contact.

**"N groups cannot be addressed to anyone."** Those alerts carry no owner. They
are shown rather than dropped: quietly skipping them is how a workload ends up
blocked with nobody warned. They need a declared fallback recipient.

### A caveat worth knowing

`cloudAccountOwners` is the owner of the **cloud account**, not of the
workload. One shared lab account produced 15 of the 52 open alerts in the
reference tenant, and one rule group addressed 5 people — so some recipients
would get mail about workloads that are not theirs.

## Reading the output

| Row | Meaning |
|---|---|
| **Rules still firing** | Distinct named rules with at least one incident in the window. |
| Rule/account groups | Rows in the table. Higher than the above when one rule fires in several accounts. |
| Total occurrences | Sum of occurrences across those groups. |
| Incidents in window (tenant total) | Server-side count for the window. Never capped by `max_alerts`. |
| Tenant-wide, all time | For proportion — is the window a slice or nearly everything? |

A rule high in the table has an unaddressed condition: the workload keeps doing
the thing the rule detects.

### Container and host are separate rows on purpose

The same rule name can exist in **both** the container and host runtime
policies. They are different rules with different owners, so they are grouped
separately. Merging them by name would point any later escalation at the wrong
policy.

### Some incidents come from the built-in model

Alerts attributed to `default` come from the built-in learned model rather than
a named rule. There is no rule to escalate by name, so they are excluded from
the table and reported as a separate line. That line explains any gap between
"incidents in window" and the table's totals.

## When the run fails on purpose

The workflow **fails deliberately** when it could not produce a report:

| Status | Meaning |
|---|---|
| `disabled` | The module was switched off. |
| `missing_credentials` | The `PRISMACLOUD_*` secrets were absent or empty. |

Both print **"Do not read this as 'nothing is firing'. Nothing was checked."**

That distinction is the point. A report that quietly renders "0 rules firing"
when it never authenticated is worse than a red X — it is a false all-clear on
a security report. Empty is never presented as good news.

> A **missing** GitHub secret arrives as an **empty string**, not null. Both are
> treated as absent; a check for null alone would let an unauthenticated run
> render as a clean report.

## Two warnings you may see

### "Partial result — the rule numbers below are from a sample"

The window held more alerts than `max_alerts` allowed the workflow to read.

This warning appears **above** the table, and the affected figures are tagged
`(sampled)`, because rules below the cut-off are missing **entirely** rather
than undercounted. A rule absent from a partial table may still be firing.
Re-run with a higher `max_alerts`.

`Incidents in window` and `Tenant-wide, all time` stay accurate — they are
server-side counts.

### "The window may not have applied"

The window returned exactly the same count as an all-time query.

The alerts API returns HTTP 200 and **the entire tenant** for a filter name it
does not recognise, so equality is what a silently dropped filter looks like.
It can also be legitimate on a quiet tenant. Confirm before treating the numbers
as a recurrence signal.

## Setup requirements

| Secret | Notes |
|---|---|
| `PRISMACLOUD_API_URL` | e.g. `api.prismacloud.io` |
| `PRISMACLOUD_USERNAME` | Access key UUID |
| `PRISMACLOUD_PASSWORD` | Secret key |

**No Compute Console secret is needed.** This workflow reads runtime incidents
after they are promoted into the CSPM alert stream, where the promoted copy
carries the runtime rule name, an occurrence count and the full dismissal
lifecycle — on the same API and auth as workflow 6.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `authentication returned no token` | Secrets missing or expired. |
| `Invalid value for variable` | `window_days` is 1–3650, `max_alerts` is 1–10000. |
| Table is empty but incidents exist | Every incident in the window came from the built-in `default` model — check the note under the table. |
| Numbers don't match workflow 7 | Different systems. Workflow 7 counts raw Compute incidents; this counts promoted CSPM alerts. Never add the two. |
| Timed out | Lower `max_alerts`, or re-run if the tenant is rate limiting. |

## More detail

- Module internals, guards and API traps:
  [`terraform/modules/runtime-grace-digest/README.md`](../../../terraform/modules/runtime-grace-digest/README.md)
- Research and decisions:
  [`plans/policy-escalation-findings.md`](../../../plans/policy-escalation-findings.md)

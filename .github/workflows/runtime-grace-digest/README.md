# Workflow 8 — Runtime Grace Digest (read-only)

Answers one question: **which runtime rules are still firing?**

It lists the rules that produced incidents inside a recent window, grouped by
rule, workload scope (container or host) and cloud account, ordered by how many
times they fired.

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
| `window_days` | `14` | The recurrence window. A rule with an incident inside it counts as still firing. |
| `alert_status` | `open` | Which lifecycle state to report. `dismissed` reviews what teams have accepted. |
| `max_alerts` | `2000` | Cap on alerts read for grouping. Totals are never capped by this. |

It also runs **automatically every Monday at 08:00 UTC** with the defaults. A
digest is only useful if it turns up without being asked for.

## Where the results appear

- **Summary page** — the report. Start here.
- **Artifact** `runtime-grace-digest` — full JSON, 90-day retention, including
  every group when the table on the summary page is truncated to the top 40.

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

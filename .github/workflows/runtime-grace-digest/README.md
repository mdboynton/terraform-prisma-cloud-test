# Workflow 8 — Runtime Grace Digest

Lists runtime rules that produced **promoted CSPM alerts** in a recent window, grouped by rule, workload scope (container/host), and cloud account, ordered by occurrence count. Optionally plans a grace-period warning campaign and, on day 14, hands overdue rules to [workflow 9](../runtime-rule-effects/README.md) for a read-only look at what could be escalated.

## How to use it

Actions → **8. Runtime Grace Digest** → Run workflow.

| Input | Default | What it does |
|---|---|---|
| `window_days` | `14` | Recurrence window. |
| `alert_status` | `open` | Lifecycle state to report on. |
| `max_alerts` | `2000` | Cap on alerts read for grouping. Totals never capped. |
| `severities` | `all severities` | Restrict to alerts promoted by a policy of that severity. |
| `plan_warnings` | off | Compute who would be warned. Sends nothing. |
| `grace_days` | `14` | Days an alert may stay open before its rule is a candidate. |
| `campaign_start_date` | *(empty)* | Required with `plan_warnings`. `YYYY-MM-DD`. |
| `send_warnings` | off | Actually send. Requires `plan_warnings`, manual dispatch, environment approval. Never on for scheduled runs. |

Reminder days (1, 3, 5, 7, 10, 13) are fixed in code, not a dispatch input.

Also runs daily at 08:00 UTC with `plan_warnings` off.

### An empty report is not the same as a clean tenant

`window_days` decides visibility. Empty result renders like a healthy tenant, so the run reports `status: empty_window` with an explicit warning when this happens.

## Where the results appear

- **Summary page** — counts only, no owner addresses.
- **Artifact** `runtime-grace-digest` (90-day retention) — full JSON, every group.

### What the artifact contains

| Key | Contents |
|---|---|
| `summary`, `scope`, `rules` | The recurrence report. |
| `notify_status`, `notify_status_detail` | Why the warning plan looks the way it does. `null` when `plan_warnings` off. |
| `warning_plan` | Counts, including `due_today` and `emails_today`. |
| `warning_messages` | One row per rule group, ages and `would_notify`. |
| `warning_accounts` | One row per account — the unit an email is sent in. |
| `escalation_handoff` / `escalation_blocked` / `escalation_ambiguous` | Day-14 groups: escalatable, blocked (built-in model), ambiguous-policy. |

> [!CAUTION]
> Artifact contains live personal email addresses, including external ones. Gitignored — never commit or paste into a ticket.

## The grace warning — planned, sent only when asked

`plan_warnings` adds a section: who would be warned, oldest open alert age, honest send count. Needs `campaign_start_date` and the override recipient.

### Sending

Mail leaves the runner only from the separate `send` job, gated on all of:

| # | Gate |
|---|---|
| 1 | `plan_warnings` on |
| 2 | `send_warnings` on |
| 3 | `workflow_dispatch` (scheduled run can never send) |
| 4 | `emails_today > 0` |
| 5 | `grace-warning-send` environment approval |
| 6 | Addressing re-verified after approval |

> [!IMPORTANT]
> Every message goes to the override recipient (`tule@paloaltonetworks.com`). Real owner addresses appear in the body labelled `TEST MODE`, never as To/Cc/Bcc.

One email per ACCOUNT, not per rule.

Required secrets: `SMTP_SERVER`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM`. Without them the send job fails; the digest still runs.

### Reading the warning plan

| Row | Meaning |
|---|---|
| Rule groups with an open alert | Candidates. |
| Past the grace window | Over threshold, counted from day 0. |
| No owner on the alert | Unroutable. |
| Not escalatable (built-in model) | The `default` learned model. |
| **Could honestly be warned today** | Overdue AND addressable AND escalatable. |

Day 0 = later of the finding's `firstSeen` and `campaign_start_date`. `cloudAccountOwners` is the account owner, not the workload owner.

## Reading the output

| Row | Meaning |
|---|---|
| Rules still firing | Distinct named rules with an incident in the window. |
| Rule/account groups | Rows in the table; higher when one rule fires in several accounts. |
| Total occurrences | Sum across those groups. |
| Incidents in window (tenant total) | Server-side count, never capped by `max_alerts`. |
| Tenant-wide, all time | For proportion. |

Container and host are separate rows. Incidents from `default` (built-in model) reported separately.

## Day 14 — handoff to workflow 9

When a rule group exhausts its grace period, this workflow can auto-call workflow 9 in read-only mode so candidate effect sites are enumerated for a human. Never escalates anything — a flip still needs manual dispatch, a hand-picked site, `APPLY` typed in, and environment approval.

| Group | Meaning |
|---|---|
| Ready for workflow 9 | Named rule, owning policy known. |
| Overdue but not escalatable | Built-in `default` model — no rule name to target. |
| Overdue, policy undetermined | Owning policy ambiguous — never guessed. |

## When the run fails on purpose

| Status | Meaning |
|---|---|
| `disabled` | Module switched off. |
| `missing_credentials` | `PRISMACLOUD_*` secrets absent or empty. |

Both render "Do not read this as 'nothing is firing'. Nothing was checked."

- **"Partial result — sampled"** — window held more alerts than `max_alerts`.
- **"The window may not have applied"** — window count equals all-time count.

## Setup requirements

| Secret | Notes |
|---|---|
| `PRISMACLOUD_API_URL` | e.g. `api.prismacloud.io` |
| `PRISMACLOUD_USERNAME` | Access key UUID |
| `PRISMACLOUD_PASSWORD` | Secret key |

No Compute Console secret needed for the digest itself.

Day-14 handoff calls workflow 9 (`secrets: inherit`), which additionally needs `PRISMA_COMPUTE_CONSOLE_URL`. Without it, `escalation_plan` reports `missing_credentials` instead of enumerating sites.

Everything below is required only by the `send` job.

## Setting up sending

1. Create the `grace-warning-send` environment (Settings → Environments), named exactly `grace-warning-send`, with at least one required reviewer and deployment branches restricted to default.

2. Add the five SMTP secrets (repository or environment scope):

   | Secret | Example | Notes |
   |---|---|---|
   | `SMTP_SERVER` | `smtp.gmail.com` | Hostname only |
   | `SMTP_PORT` | `587` | `587` (STARTTLS) or `465` (implicit TLS). Port 25 blocked on GitHub-hosted runners. |
   | `SMTP_USERNAME` | `you@gmail.com` | Provider-specific |
   | `SMTP_PASSWORD` | *(token)* | API key or app password, not a login password |
   | `SMTP_FROM` | same as `SMTP_USERNAME` | Must be authorised by the relay |

<details>
<summary>Which relay to use</summary>

1. Personal Gmail + App Password (see below). App Passwords are disabled by policy on `paloaltonetworks.com`.
2. Transactional provider (SendGrid, Mailgun, SES, Postmark). `SMTP_FROM` still can't be `@paloaltonetworks.com`.
3. Internal relay accepting authenticated submission from the internet.
4. Self-hosted runner inside the network, if IP-authorised relay is the only option.

Not the Prisma Cloud tenant — `/settings/smtp` returns 404.

### Sending via Gmail

Personal Gmail account required. `SMTP_FROM` must be the Gmail address itself. Recipient stays the pinned override address.

App Password: enable 2-Step Verification, then myaccount.google.com/apppasswords → copy the 16 characters without spaces.

Free-tier limit ~500 recipients/day. Check Spam before concluding a send failed. Revoke the App Password after the test phase.

</details>

### Prove it with the smallest possible send

1. Dispatch with `plan_warnings` on, `send_warnings` off. Read `emails_today`.
2. Download the artifact, confirm every `warning_accounts[].recipient` is the override address.
3. Re-dispatch with `send_warnings` on, approve the environment.
4. Read one message — body carries real owners under `TEST MODE:`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `authentication returned no token` | Secrets missing or expired. |
| `Invalid value for variable` | `window_days` is 1–3650, `max_alerts` is 1–10000. |
| Table is empty but incidents exist | Every incident in the window came from the built-in `default` model. |
| Numbers don't match workflow 7 | Different systems — workflow 7 counts raw Compute incidents, this counts promoted CSPM alerts. |
| Timed out | Lower `max_alerts`, or re-run if rate limited. |

## More detail

- Module internals, guards, API traps: [`terraform/modules/runtime-grace-digest/README.md`](../../../terraform/modules/runtime-grace-digest/README.md)
- Workflow 9: [`.github/workflows/runtime-rule-effects/README.md`](../runtime-rule-effects/README.md)
- Research and decisions: [`plans/policy-escalation-findings.md`](../../../plans/policy-escalation-findings.md)

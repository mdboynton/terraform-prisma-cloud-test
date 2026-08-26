# Workflow 8 — Runtime Grace Digest

Lists runtime rules that produced **promoted CSPM alerts** in a recent window, grouped by rule, workload scope (container/host), and cloud account, ordered by occurrence count. Optionally plans a grace-period warning campaign and, on day 14, hands overdue rules to [workflow 9](../runtime-rule-effects/README.md) for a read-only look at what could be escalated.

> "Incident" = raw runtime event in the Compute Console. CSPM promotes it into an "alert". This workflow reads alerts (CSPM alert API), never the Compute Console — this page says "alert".

**Can it change the tenant?** No — `data` blocks only, zero `resource` blocks.

> [!IMPORTANT]
> Can still send email and trigger a read-only workflow 9 run. Neither touches the tenant, but sending mail is irreversible. `send` job is off by default, impossible on a schedule, behind an environment approval.

Reports recurrence ("still firing in the last N days"), not age — incidents never expire (14,398 of 14,410 are older than 14 days on the reference tenant), so an age-based report would list almost everything forever.

## How to use it

Actions → **8. Runtime Grace Digest** → Run workflow.

| Input | Default | What it does |
|---|---|---|
| `window_days` | `14` | Recurrence window. |
| `alert_status` | `open` | Lifecycle state to report on. |
| `max_alerts` | `2000` | Cap on alerts read for grouping. Totals never capped. |
| `severities` | `all severities` | Restrict to alerts promoted by a policy of that severity. Every runtime alert on this tenant is `high`. |
| `plan_warnings` | off | Compute who would be warned. Sends nothing. |
| `grace_days` | `14` | Days an alert may stay open before its rule is a candidate. |
| `campaign_start_date` | *(empty)* | Required with `plan_warnings`. `YYYY-MM-DD`. |
| `send_warnings` | off | Actually send. Requires `plan_warnings`, manual dispatch, environment approval. Never on for scheduled runs. |

Reminder days (1, 3, 5, 7, 10, 13) are fixed in code, not a dispatch input.

Also runs daily at 08:00 UTC with `plan_warnings` off — `campaign_start_date` has no default (today's date would restart every countdown; a fixed past date would tell owners their grace expired before it started), so a scheduled run reports `no_campaign_start` and plans nothing.

### An empty report is not the same as a clean tenant

`window_days` decides visibility. Measured: 14-day default returns 0 open alerts; 1825 days returns 111. Empty result renders like a healthy tenant, so the run reports `status: empty_window` with an explicit warning.

### The severity dropdown is not a text box

`policy.severity` fails open — an unrecognized value (typo, wrong case, comma-joined `"high,critical"`) is silently ignored and the API returns every severity at HTTP 200. Enforced via dropdown + Terraform validation + post-fetch assertion.

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

Every `recipient` in the artifact is checked against the override address before writing; the run fails if any row disagrees or the expected address is missing.

## The grace warning — planned, sent only when asked

`plan_warnings` adds a section: who would be warned, oldest open alert age, honest send count. Needs `campaign_start_date` and the override recipient. No SMTP client — plan-only.

### Sending

Mail leaves the runner only from the separate `send` job, gated on all of:

| # | Gate |
|---|---|
| 1 | `plan_warnings` on |
| 2 | `send_warnings` on |
| 3 | `workflow_dispatch` (scheduled run can never send) |
| 4 | `emails_today > 0` |
| 5 | `grace-warning-send` environment approval |
| 6 | Addressing re-verified after approval — send job re-reads the artifact and re-asserts the override address |

> [!IMPORTANT]
> Every message goes to the override recipient (`tule@paloaltonetworks.com`). Real owner addresses appear in the body labelled `TEST MODE`, never as To/Cc/Bcc.

One email per ACCOUNT, not per rule — owners are a property of the account (26 sends collapse to 5 emails on the reference tenant).

Required secrets: `SMTP_SERVER`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM`. Without them the send job fails; the digest still runs.

### Reading the warning plan

| Row | Meaning |
|---|---|
| Rule groups with an open alert | Candidates. |
| Past the grace window | Over threshold, counted from day 0. |
| No owner on the alert | Unroutable. |
| Not escalatable (built-in model) | The `default` learned model. |
| **Could honestly be warned today** | Overdue AND addressable AND escalatable. |

### When the clock starts

Day 0 = later of the finding's `firstSeen` and `campaign_start_date`. Every open finding on the reference tenant is already older than 14 days, so counting from `firstSeen` alone would tell everyone their grace expired before they knew it started. Not stored between runs — recomputed each time.

- "N groups cannot be addressed to anyone" on a first run is expected.
- `cloudAccountOwners` is the account owner, not the workload owner — one shared account can address people about workloads that aren't theirs.

## Reading the output

| Row | Meaning |
|---|---|
| Rules still firing | Distinct named rules with an incident in the window. |
| Rule/account groups | Rows in the table; higher when one rule fires in several accounts. |
| Total occurrences | Sum across those groups. |
| Incidents in window (tenant total) | Server-side count, never capped by `max_alerts`. |
| Tenant-wide, all time | For proportion. |

Container and host are separate rows — same rule name can exist in both policies. Incidents from `default` (built-in model) reported separately — no rule name to escalate.

## Day 14 — handoff to workflow 9

When a rule group exhausts its grace period, this workflow can auto-call workflow 9 in read-only mode so candidate effect sites are enumerated for a human.

Two jobs run after `digest`, only when day-14 groups exist (`esc_ready > 0`):

- **`escalation_gate`** — skips if a workflow 9 run is already waiting on approval (fails open if the GitHub API query itself fails).
- **`escalation_plan`** — `workflow_call` into `runtime-rule-effects.yml`, passing `window_days` and `alert_status: "open"` (fixed regardless of this run's status).

> [!IMPORTANT]
> Never escalates anything. Workflow 9's `workflow_call` trigger declares no `escalate_*`/`confirm` inputs, and its `apply` job refuses `workflow_call` events. A flip still needs manual dispatch, a hand-picked site, `APPLY` typed in, and environment approval — decision recorded in `plans/policy-escalation-findings.md`.

| Group | Meaning |
|---|---|
| Ready for workflow 9 | Named rule, owning policy known. |
| Overdue but not escalatable | Built-in `default` model — no rule name to target. Majority of overdue backlog (51 of 111) on the reference tenant. |
| Overdue, policy undetermined | Owning policy ambiguous — never guessed (some rule names exist in both container and host policies). |

## When the run fails on purpose

| Status | Meaning |
|---|---|
| `disabled` | Module switched off. |
| `missing_credentials` | `PRISMACLOUD_*` secrets absent or empty. |

Both render "Do not read this as 'nothing is firing'. Nothing was checked."

- **"Partial result — sampled"** — window held more alerts than `max_alerts`; affected figures tagged `(sampled)`.
- **"The window may not have applied"** — window count equals all-time count, which is what a silently-dropped filter looks like.

## Setup requirements

| Secret | Notes |
|---|---|
| `PRISMACLOUD_API_URL` | e.g. `api.prismacloud.io` |
| `PRISMACLOUD_USERNAME` | Access key UUID |
| `PRISMACLOUD_PASSWORD` | Secret key |

No Compute Console secret needed for the digest itself — reads promoted CSPM alerts, same API/auth as workflow 6.

Day-14 handoff calls workflow 9 (`secrets: inherit`), which additionally needs `PRISMA_COMPUTE_CONSOLE_URL`. Without it, `escalation_plan` reports `missing_credentials` instead of enumerating sites.

Everything below is required only by the `send` job — without it the digest and handoff still run as described.

## Setting up sending

1. Create the `grace-warning-send` environment (Settings → Environments), named exactly `grace-warning-send`, with at least one required reviewer and deployment branches restricted to default. Separate from `test-tenant` (workflows 1, 2, 9) — one gates tenant writes, the other gates contacting humans.

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

GitHub-hosted runners have arbitrary IPs, so IP-allowlisted relays don't work — needs credential auth.

1. Personal Gmail + App Password (see below). App Passwords are disabled by policy on `paloaltonetworks.com`.
2. Transactional provider (SendGrid, Mailgun, SES, Postmark) — long-term answer. `SMTP_FROM` still can't be `@paloaltonetworks.com` (SPF per-IP allowlist under DMARC `p=reject` rejects it).
3. Internal relay accepting authenticated submission from the internet — only route that can send as the work domain.
4. Self-hosted runner inside the network, if IP-authorised relay is the only option.

Not the Prisma Cloud tenant — `/settings/smtp` returns 404.

### Sending via Gmail

Personal Gmail account required (App Passwords policy-disabled on corporate Workspace). `SMTP_FROM` must be the Gmail address itself. Recipient stays the pinned override address.

App Password: enable 2-Step Verification, then myaccount.google.com/apppasswords → copy the 16 characters without spaces.

Verified against this domain's SPF/DKIM/DMARC (2026-08-21): Google's submission path passes `paloaltonetworks.com`'s per-IP SPF allowlist; a GitHub-runner sending directly fails it — must relay through `smtp.gmail.com`.

Free-tier limit ~500 recipients/day, far above campaign volume. Check Spam before concluding a send failed. Revoke the App Password after the test phase.

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

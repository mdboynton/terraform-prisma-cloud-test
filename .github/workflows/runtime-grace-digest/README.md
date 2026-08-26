# Workflow 8 — Runtime Grace Digest

Answers one question: **which runtime rules are still firing?**

It lists rules that produced **promoted CSPM alerts** inside a recent window,
grouped by rule, workload scope (container/host) and cloud account, ordered by
occurrence count. Turned on, it also plans a grace-period warning campaign and,
on day 14, hands overdue rules to [workflow 9](../runtime-rule-effects/README.md)
for a read-only look at what could be escalated.

> **"Incident" vs "alert".** An *incident* is the raw runtime event in the
> Compute Console. CSPM promotes it into an *alert*. **This workflow reads
> alerts** — the CSPM alert API, never the Compute Console — so this page says
> "alert" for the thing being counted.

## Why "cannot" rather than "does not"

The `runtime-grace-digest` module contains only `data` blocks — no
`resource` blocks. There is nothing for an apply to apply, so **no run of this
workflow can change the tenant**. That is guaranteed by the module's
construction, not by a policy someone could forget.

> [!IMPORTANT]
> **It can still send email**, and it can still trigger a **read-only** run of
> workflow 9. Neither of those touches the tenant, but sending mail is
> irreversible — see [Sending](#sending). The `send` job is off by default,
> impossible on a schedule, and behind an environment approval.

## It reports recurrence, not "unresolved for N days"

A **runtime incident is an event**, not a state — it happened, and nothing
makes it un-happen. There's no "resolved" state to age against, and incidents
never expire. On the reference tenant, 14,398 of 14,410 incidents are older
than 14 days, so an age-based report would list almost everything forever.

**"Still firing in the last N days"** is the question the data can answer, and
it clears itself: fix the workload, the incidents stop, the rule drops off the
report.

## How to use it

Actions → **8. Runtime Grace Digest** → Run workflow.

| Input | Default | What it does |
|---|---|---|
| `window_days` | `14` | Recurrence window. A short window can legitimately return nothing while the tenant is full of alerts — see below. |
| `alert_status` | `open` | Lifecycle state to report on. |
| `max_alerts` | `2000` | Cap on alerts read for grouping. Totals are never capped by this. |
| `severities` | `all severities` | Restrict to alerts promoted by a policy of that severity. On this tenant every runtime alert is `high`. |
| `plan_warnings` | off | Also compute **who would be warned** that a rule is heading for escalation. Sends nothing. |
| `grace_days` | `14` | Days an alert may stay open before its rule is a candidate. Only used with `plan_warnings`. |
| `campaign_start_date` | *(empty)* | **Required with `plan_warnings`.** `YYYY-MM-DD`, the day the campaign was announced. |
| `send_warnings` | off | **Actually send** the planned warnings. Requires `plan_warnings`, a manual dispatch, and an environment approval. Never on for scheduled runs. |

Reminder days (1, 3, 5, 7, 10, 13) are fixed, not a dispatch input — they are a
property of the campaign, agreed once. Changing them is a code review, not a
run parameter.

It also runs **automatically every day at 08:00 UTC**, with `plan_warnings`
**off** — see below for why.

### Why daily, and why the schedule doesn't plan warnings

The campaign contacts owners on exact days (1, 3, 5, 7, 10, 13) of a 14-day
grace period. A weekly cron only ever lands on two of those, so the schedule
has to look every day. Daily does **not** mean daily email — most days a group
is mid-period and the plan reports nothing.

`plan_warnings` stays off on the schedule because `campaign_start_date` has no
default: today's date would restart every countdown on every run, and a fixed
past date would tell owners their grace expired before they were told it
existed. A scheduled run supplies an empty date, the module reports
`no_campaign_start`, and plans nothing — deliberately, rather than silently
running a broken campaign. To put the campaign on the cron, the start date
needs to become a committed repository variable, which is a decision about the
campaign, not a workflow tweak.

### An empty report is not the same as a clean tenant

`window_days` decides what you can see. Measured on the reference tenant: the
14-day default returns **0** open alerts; 1825 days returns **111**. An empty
result renders exactly like a healthy tenant, so the run reports
`status: empty_window` with an explicit warning whenever this happens.

**This matters most for the day-14 handoff to workflow 9** (below): if this
window is narrower than the population workflow 9 escalates against, the
digest warns fewer people than get affected — or nobody at all.

### The severity dropdown is not a text box

`policy.severity` **fails open**: an unrecognised value (a typo, wrong case, or
the comma-joined `"high,critical"`) is silently ignored and the API returns
**every** severity at HTTP 200. A free-text box here would let one typo widen
a blocking campaign to the whole tenant with nothing in the report saying so.
The dropdown, a Terraform validation, and a post-fetch assertion on every
returned alert's severity all back this up.

## Where the results appear

- **Summary page** — the report. Counts only; no owner address is ever printed
  here, since the summary is visible to anyone with repo read access.
- **Artifact** `runtime-grace-digest` (90-day retention) — full JSON, including
  every group when the summary table is truncated to the top 40.

### What the artifact contains

| Key | Contents |
|---|---|
| `summary`, `scope`, `rules` | The recurrence report. |
| `notify_status`, `notify_status_detail` | Why the warning plan looks the way it does. `null` when `plan_warnings` is off. |
| `warning_plan` | Counts, including `due_today` and `emails_today`. |
| `warning_messages` | One row per **rule group**, with ages and `would_notify`. |
| `warning_accounts` | One row per **account** — the unit an email is sent in. |
| `escalation_handoff` / `escalation_blocked` / `escalation_ambiguous` | Day-14 groups: escalatable, blocked (built-in model), and ambiguous-policy — see [Day 14](#day-14--handoff-to-workflow-9) below. |

> [!CAUTION]
> **The artifact contains live personal email addresses**, including external
> ones, read from the alerts' `cloudAccountOwners`. It is gitignored and must
> never be committed or pasted into a ticket.

Every `recipient` in the artifact is checked against the override address
before the file is written; the run **fails** if any row disagrees, and fails
if the expected address is missing entirely rather than silently passing.

## The grace warning — planned, and sent only when you ask

Turn on `plan_warnings` and the report gains a section: who *would* be warned,
how old the oldest open alert is, and how many messages could honestly be
sent. Planning needs **two** required values — `campaign_start_date` and the
override recipient — and sends nothing; the module has no SMTP client at all.

### Sending

Mail leaves the runner only from the separate **`send`** job, gated on every
one of:

| # | Gate | Why |
|---|---|---|
| 1 | `plan_warnings` on | There has to be a plan. |
| 2 | `send_warnings` on | Asked for explicitly, this run. |
| 3 | `workflow_dispatch` | A scheduled run can **never** send. |
| 4 | `emails_today > 0` | Nobody approves a mailing of zero. |
| 5 | `grace-warning-send` environment approval | A second human. |
| 6 | Addressing re-verified after approval | Approving an environment does not re-run the plan-time checks; the send job re-reads the artifact and re-asserts the override address before composing anything. |

> [!IMPORTANT]
> **Every message goes to the override recipient**, currently
> `tule@paloaltonetworks.com`. Real owner addresses appear *in the body*,
> labelled `TEST MODE`, for review only — never as a `To:`, `Cc:` or `Bcc:`.

**One email per ACCOUNT, not per rule** — owners are a property of the cloud
account, so rule-level sends would repeat the same people (measured: 26 sends
collapse to 5 emails on the reference tenant).

Required secrets: `SMTP_SERVER`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`,
`SMTP_FROM`. Without them the send job fails; the digest still runs.

### Reading the warning plan

| Row | Meaning |
|---|---|
| Rule groups with an open alert | Candidates. |
| Past the grace window | Over threshold, counted from day 0. |
| No owner on the alert (unroutable) | Cannot be addressed to anyone. |
| Not escalatable (built-in model) | The `default` learned model. |
| **Could honestly be warned today** | Overdue **and** addressable **and** escalatable. |

### When the clock starts

Day 0 is **the later of** the finding's `firstSeen` and `campaign_start_date`
— not simply how old the finding is. Every open finding on the reference
tenant is already older than a 14-day grace period, so counting from
`firstSeen` alone would tell everyone their grace expired before they were
ever told it started. The announcement date sets day 0 for the backlog;
anything appearing later starts from its own first sighting. Nothing is
stored between runs — the countdown is recomputed from the API every time.

### Two things worth knowing

- **"N groups cannot be addressed to anyone"** on a first run is expected —
  those alerts carry no owner and need a declared fallback recipient.
- **`cloudAccountOwners` is the owner of the cloud account, not the
  workload.** One shared account can address several people about workloads
  that aren't theirs.

## Reading the output

| Row | Meaning |
|---|---|
| **Rules still firing** | Distinct named rules with an incident in the window. |
| Rule/account groups | Rows in the table; higher than the above when one rule fires in several accounts. |
| Total occurrences | Sum across those groups. |
| Incidents in window (tenant total) | Server-side count, never capped by `max_alerts`. |
| Tenant-wide, all time | For proportion — is the window a slice or nearly everything? |

**Container and host are separate rows on purpose** — the same rule name can
exist in both policies, and merging them would point a later escalation at the
wrong one. **Incidents from `default`** (the built-in learned model) are
reported separately: there's no rule name to escalate, so they're excluded
from the table and explain any gap between the totals.

## Day 14 — handoff to workflow 9

When a rule group has used its full grace period, this workflow can
**automatically call workflow 9 in its read-only mode** so the candidate
effect sites are enumerated and waiting for a human, instead of relying on
someone noticing the digest and running workflow 9 by hand.

Two jobs run after `digest`, only when `plan_warnings` found day-14 groups
(`esc_ready > 0`):

- **`escalation_gate`** — checks whether a workflow 9 run is already sitting
  on an approval (`status=waiting`). If one is, a human has already been asked
  this exact question and hasn't answered yet, so this run does **not** queue
  a duplicate plan behind it — it reports "skipped" and stops. This check
  fails **open**: if the GitHub API query itself fails, the run proceeds
  rather than silently skipping.
- **`escalation_plan`** — a `workflow_call` into `runtime-rule-effects.yml`,
  passing this run's `window_days` and `alert_status: "open"` (fixed,
  regardless of what this digest run was reporting on, since escalation is
  always about currently-open alerts).

> [!IMPORTANT]
> **This never escalates anything.** Workflow 9's `workflow_call` trigger
> declares no `escalate_*` or `confirm` inputs — a caller has no way to name a
> target or confirm a write — and its `apply` job additionally refuses to run
> for a `workflow_call` event. Flipping a rule to prevent/block still needs a
> manual dispatch of workflow 9, a site chosen by hand, `APPLY` typed in, and
> an environment approval. Keeping the flip human-gated is a recorded decision
> — see `plans/policy-escalation-findings.md`, "Workflow 9 must stay
> human-gated". For runtime rules the enforcement runs on the workload itself,
> so an unattended flip can start blocking production traffic unwatched.

The digest's own summary page separately reports three groups once a day-14
candidate exists:

| Group | Meaning |
|---|---|
| Ready for workflow 9 | Named rule, owning policy known — an actionable candidate. |
| Overdue but not escalatable | Came from the built-in `default` model, which has no rule name to target. On the reference tenant this is the *majority* of the overdue backlog (51 of 111 incidents) — reported rather than dropped, so the actionable list isn't mistaken for the whole picture. |
| Overdue, policy undetermined | The owning policy couldn't be determined from the alert. **Never guessed** — three rule names exist in both the container and host policies, and escalating the wrong one changes an unrelated control. |

## When the run fails on purpose

| Status | Meaning |
|---|---|
| `disabled` | The module was switched off. |
| `missing_credentials` | The `PRISMACLOUD_*` secrets were absent or empty. |

Both render **"Do not read this as 'nothing is firing'. Nothing was
checked."** — a quiet "0 rules firing" on an unauthenticated run would be a
false all-clear on a security report.

Two more warnings you may see:

- **"Partial result — sampled"** — the window held more alerts than
  `max_alerts` allowed. Affected figures are tagged `(sampled)`; a rule absent
  from a partial table may still be firing.
- **"The window may not have applied"** — the window returned the same count
  as an all-time query, which is what a silently-dropped filter looks like
  (the alerts API returns HTTP 200 and the whole tenant for a filter name it
  doesn't recognise). Can also be legitimate on a quiet tenant.

## Setup requirements

| Secret | Notes |
|---|---|
| `PRISMACLOUD_API_URL` | e.g. `api.prismacloud.io` |
| `PRISMACLOUD_USERNAME` | Access key UUID |
| `PRISMACLOUD_PASSWORD` | Secret key |

**No Compute Console secret is needed for the digest itself** — it reads
runtime incidents after they're promoted into the CSPM alert stream, on the
same API and auth as workflow 6. These three secrets are all the **digest**
needs.

**The day-14 handoff is different**: it calls workflow 9 (`secrets:
inherit`), which additionally needs `PRISMA_COMPUTE_CONSOLE_URL` to read
effect state from the Compute Console — see workflow 9's own setup section.
Without it, `escalation_plan` runs but reports `missing_credentials` rather
than enumerating sites.

Everything else below is required only by the `send` job; without it the
digest and the handoff still run exactly as described.

## Setting up sending

1. **Create the `grace-warning-send` environment** — Settings → Environments →
   New environment, named exactly `grace-warning-send`. Add at least one
   **required reviewer** (an environment with none doesn't pause — this is the
   whole point of the gate), and restrict **deployment branches** to your
   default branch. This is deliberately a *different* environment from
   `test-tenant` (used by workflows 1, 2 and 9): one gates writes to the
   tenant, the other gates contacting humans, and they shouldn't share reviewers.

2. **Add the five SMTP secrets** (repository, or on the environment for
   stricter scoping):

   | Secret | Example | Notes |
   |---|---|---|
   | `SMTP_SERVER` | `smtp.gmail.com` | Hostname only |
   | `SMTP_PORT` | `587` | `587` (STARTTLS) or `465` (implicit TLS), both supported. **Port 25 is blocked on GitHub-hosted runners.** |
   | `SMTP_USERNAME` | `you@gmail.com` | Provider-specific |
   | `SMTP_PASSWORD` | *(token)* | An API key or app password, **not** a login password |
   | `SMTP_FROM` | same as `SMTP_USERNAME` | Must be an address the relay is authorised to send as |

<details>
<summary>Which relay to use, and why a corporate IP-allowlisted relay won't work</summary>

A GitHub-hosted runner has an arbitrary, ever-changing IP, so a relay that
authorises by source IP has nothing to allowlist. The relay must authenticate
with credentials instead. Options, least friction first for this domain:

1. **A personal Gmail account with an App Password** (recommended starting
   point, see below). App Passwords are **disabled by admin policy** on
   `paloaltonetworks.com` — confirmed, not something to work around.
2. **A transactional provider** (SendGrid, Mailgun, SES, Postmark) — the right
   long-term answer. `SMTP_FROM` still can't be `@paloaltonetworks.com`: its
   SPF is a per-IP allowlist under DMARC `p=reject`, so anything not on that
   list is **rejected**, not junked.
3. **An internal relay that accepts authenticated submission from the
   internet** — the only route that can legitimately send *as* the work
   domain.
4. **A self-hosted runner inside the network**, if an IP-authorised relay is
   the only option.

**Not the Prisma Cloud tenant** — `/settings/smtp` returns 404; there's no
relay to borrow.

### Sending via Gmail

Use a **personal** Gmail account (App Passwords are policy-disabled on the
corporate Workspace domain). `SMTP_FROM` must be the Gmail address itself —
Gmail only lets you send as a verified address. The recipient still stays the
pinned override address; mail simply arrives from the personal account, which
for a test campaign is honest labelling, not a defect.

To get the App Password: enable 2-Step Verification
(myaccount.google.com → Security), then
myaccount.google.com/apppasswords → name it → copy the 16 characters (paste
without the spaces Google displays). Your normal password will not work.

Verified against this domain's actual SPF/DKIM/DMARC records (2026-08-21):
Google's own submission path passes `paloaltonetworks.com`'s per-IP SPF
allowlist with nothing to arrange, while a GitHub-runner or arbitrary IP
sending directly fails it — confirmed with real Google source IPs (pass) and
bogus control IPs (fail), so the runner must always hand off through
`smtp.gmail.com` rather than attempt to send to the world directly.

Free-tier limits (~500 recipients/day) are far above this campaign's volume.
Mail may land in Spam — check before concluding a send failed. Revoke the App
Password when the test phase ends; it's a real credential to a personal
mailbox and not how a production campaign should send mail (move to a service
mailbox or transactional provider first).

</details>

### Prove it with the smallest possible send

1. Dispatch with `plan_warnings` on, `send_warnings` **off**. Read
   `emails_today` on the summary — if that number surprises you, stop.
2. Download the artifact, confirm every `warning_accounts[].recipient` is the
   override address (the run already fails otherwise — this is you checking
   the check).
3. Re-dispatch with `send_warnings` on and approve the environment. Every
   message goes to the override recipient, so the worst case is a small pile
   of mail in one inbox.
4. Read one — the body carries the real owners under `TEST MODE:`, which is
   the addressing you'd be using for real.

Only after that is it worth discussing sending to real owners, which is a
change to the pinned recipient and a separate conversation.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `authentication returned no token` | Secrets missing or expired. |
| `Invalid value for variable` | `window_days` is 1–3650, `max_alerts` is 1–10000. |
| Table is empty but incidents exist | Every incident in the window came from the built-in `default` model. |
| Numbers don't match workflow 7 | Different systems — workflow 7 counts raw Compute incidents, this counts promoted CSPM alerts. Don't add them. |
| Timed out | Lower `max_alerts`, or re-run if the tenant is rate limiting. |

## More detail

- Module internals, guards and API traps:
  [`terraform/modules/runtime-grace-digest/README.md`](../../../terraform/modules/runtime-grace-digest/README.md)
- Workflow 9 (the escalation this hands off to):
  [`.github/workflows/runtime-rule-effects/README.md`](../runtime-rule-effects/README.md)
- Research and decisions:
  [`plans/policy-escalation-findings.md`](../../../plans/policy-escalation-findings.md)

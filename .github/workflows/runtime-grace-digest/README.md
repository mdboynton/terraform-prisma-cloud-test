# Workflow 8 — Runtime Grace Digest

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
`resource` blocks. There is nothing for an apply to apply. **No run of this
workflow can change the tenant**, and that comes from the module's
construction, not from a policy someone could forget.

> [!IMPORTANT]
> **It can still send email.** "Cannot change the tenant" is not "cannot do
> anything irreversible" — those are different claims, and only the first one
> is guaranteed by construction here. Mail leaves from the separate `send`
> job, which is off by default, impossible on a schedule, and behind an
> environment approval. See [Sending](#sending).

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
| `severities` | `all severities` | Restrict to alerts promoted by a policy of that severity. On this tenant every runtime alert is `high`, so only `all severities` and `high`-inclusive options return anything — see below. |
| `plan_warnings` | off | Also work out **who would be warned** that a rule is heading for escalation. Sends nothing. |
| `grace_days` | `14` | Days an alert may stay open before its rule becomes a candidate. Only used with `plan_warnings`. |

The reminder days themselves (1, 3, 5, 7, 10, 13) are **not** a dispatch input.
They are a property of the campaign, agreed once — varying them per run would
silently move everyone's reminder days mid-flight. Changing them is a code
review.

It also runs **automatically every day at 08:00 UTC** with the defaults.

### Why daily

The campaign contacts owners on days **1, 3, 5, 7, 10 and 13** of a 14-day
grace period, then escalates on day 14. A weekly cron cannot deliver that: it
only ever observes two of those days, and days 3 and 10 are mid-week by
construction. Seeing the schedule at all requires looking every day.

**Daily does not mean daily email.** The plan is a pure function of each
finding's age — on most days a group is mid-period and reports nothing. The
cost of a run is one read-only pass over the alerts API.

A consequence worth knowing: because the schedule is a set of exact days and
nothing records what was sent, **a missed run is a missed notice**. If the cron
does not fire on day 3, the next contact is day 5.

### ⚠️ The scheduled run does not plan warnings

`plan_warnings` is **off** on the schedule, so the daily run reports recurrence
but does not compute who is due a reminder. The campaign runs when someone
dispatches the workflow with `plan_warnings` on.

**The reason is a dependency, not caution.** `campaign_start_date` has no
default on purpose — today's date would restart every countdown on every run,
and a fixed past date would tell owners their grace expired before they were
told it existed. A scheduled run therefore supplies an empty date, and the
module requires one before it will plan anything. Measured, with planning
forced on and no date:

```
notify_status = no_campaign_start
warning_plan  = null
```

So switching this on would produce a daily job that *looks* like it is running
the campaign and computes nothing — worse than being visibly off.

Safety is no longer the blocker: the `send` job cannot run on a scheduled event
at all, so a planning cron cannot become a mailing cron by config change. To
put the campaign on the schedule, the start date has to become a committed
value (a repository variable) rather than a per-run input — a decision about
the campaign, not a workflow tweak.

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

### The severity dropdown, and why it is a dropdown

Runtime incidents reach CSPM through one of two built-in policies — *Container
workloads detected with Runtime Incidents* and its Host counterpart — and
**both hardcode `high`**. Measured on this tenant: 111 of 111 open runtime
alerts are `high`, and none are `critical`. So `high + critical` returns the
same 111 rows as `all severities`, and `critical only` returns 0. That is
correct behaviour, not a broken filter.

The option exists because a tenant with custom promoting policies will carry a
real spread, and because a campaign scoped to high and critical should say so
in the query.

**It is a dropdown rather than a text box for a specific reason.** The severity
filter *fails open*: an unrecognised value — including `High` with a capital H,
or the comma-joined `high,critical` — is silently ignored and the API returns
**every** severity, at HTTP 200, with a count that looks perfectly normal.
Every other filter here fails the safe way, returning zero. A free-text box
would let one typo widen a campaign that eventually blocks workloads, with
nothing in the report saying so.

Three guards back this up: the dropdown, Terraform variable validation, and a
post-fetch assertion that checks the severity of every alert that came back and
fails the run if any fall outside the request. The header line on the summary
page always states the severity scope, so an unfiltered report says "all
severities" rather than leaving you to assume.

## Where the results appear

- **Summary page** — the report. Start here. Counts only: no owner address is
  ever printed here, because the summary is visible to everyone with repo read
  access.
- **Artifact** `runtime-grace-digest` — full JSON, 90-day retention, including
  every group when the table on the summary page is truncated to the top 40.

### What the artifact contains

| Key | Contents |
|---|---|
| `summary`, `scope`, `rules` | The recurrence report, as rendered above. |
| `notify_status`, `notify_status_detail` | Why the warning plan looks the way it does. `null` when `plan_warnings` is off. |
| `warning_plan` | The counts, including `due_today` and `emails_today`. |
| `warning_messages` | One row per **rule group**, with ages and `would_notify`. |
| `warning_accounts` | One row per **account** — the unit an email is sent in. |

> [!CAUTION]
> **The artifact contains live personal email addresses**, including external
> ones, read from the alerts' `cloudAccountOwners`. It is gitignored and must
> not be committed or pasted into a ticket.

The warning keys were missing for several revisions while the summary page
already told readers "the artifact has all of them, with recipients". It did
not: the file held `summary`, `scope` and `rules` only, so anyone who followed
that sentence found no ages and no recipients. The addressing record and the
report are now the same file.

Every `recipient` in the artifact is checked against the override address
before the file is written, and the run **fails** if any row disagrees. If the
expected address is missing entirely the run also fails, rather than comparing
against an empty string and reporting the correct address as the violation —
a check that cannot run must stop the run, not pass it.

## The grace warning — planned, and sent only when you ask

Turn on `plan_warnings` and the report gains a second section: who *would* be
told that a rule is heading for escalation, how old the oldest open alert is,
and how many of those messages could honestly be sent.

`plan_warnings` needs **two** values, and neither has a default:
`campaign_start_date` (the day you announced the campaign) and the override
recipient. Leave the date out and the run reports `no_campaign_start` and plans
nothing — see "When the clock starts" below for why it is not optional.

Planning still sends nothing. The module itself has no SMTP client, no webhook
and no mail command; it computes a plan and stops.

### Sending

Mail leaves the runner only from the separate **`send`** job, and only when
every one of these is true:

| # | Gate | Why |
|---|---|---|
| 1 | `plan_warnings` on | There has to be a plan. |
| 2 | `send_warnings` on | Asked for explicitly, this run. |
| 3 | `workflow_dispatch` | **A scheduled run can never send.** |
| 4 | `emails_today > 0` | Nobody approves a mailing of zero. |
| 5 | `grace-warning-send` environment approval | A second human. |
| 6 | Addressing re-verified after approval | See below. |

Gate 3 is what makes the daily cron safe: the schedule computes who is due and
is structurally unable to tell them.

Gate 6 exists because **approving an environment does not re-run the earlier
checks**. Between the plan and the approval sit an artifact round-trip and a
human who may click hours later. The send job therefore re-reads the artifact
and re-asserts that every recipient is the override before composing anything.
If the expected address is missing it refuses rather than comparing against an
empty string.

> [!IMPORTANT]
> **Every message goes to the override recipient**, currently
> `tule@paloaltonetworks.com`. The real owner addresses appear *in the body*,
> labelled `TEST MODE`, so the addressing can be reviewed against real data —
> they are never used as a `To:`, `Cc:` or `Bcc:`.

That asymmetry is deliberate. Every other workflow here can only affect the
tenant, and a wrong write is undone by another write. These recipients are
**live mailboxes of real people**, read from the alert's `cloudAccountOwners`
and including addresses outside the company. A sent email cannot be recalled.

**One email per ACCOUNT, not per rule.** Owners are a property of the cloud
account, so rule-level sends mail the same people repeatedly — measured on the
reference tenant, 26 sends collapse to 5 emails carrying identical information.

Required secrets: `SMTP_SERVER`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`,
`SMTP_FROM`. Without them the send job fails; the digest still runs.

### Reading it

| Row | Meaning |
|---|---|
| Rule groups with an open alert | Candidates. Only `open` alerts run the clock. |
| Past the grace window | Already over the threshold, counted from day 0. |
| Started before the campaign (backlog) | Day 0 came from the announcement, not the finding. Normally every group on a first run. |
| No owner on the alert (unroutable) | Cannot be addressed to anyone. |
| Not escalatable (built-in model) | The `default` learned model — no escalation can target it. |
| **Could honestly be warned today** | Overdue **and** addressable **and** escalatable. |
| Distinct people who would be contacted | Fan-out, before any message is written. |
| Most recipients on a single group | How many people one rule would notify. |

Only the **counts** appear on the summary page — it is visible to everyone with
repo read access. The addresses are in the artifact.

### When the clock starts

Day 0 is **the later of** the finding's own `firstSeen` **and**
`campaign_start_date` — not simply how old the finding is.

This matters more than it sounds. Measured against the reference tenant, every
open finding is already older than a 14-day grace period (min 29 days, median
150, max 371). Counting from `firstSeen` alone means the first run tells
everyone their grace period expired before they were ever told it had started.
That is an ambush, not a warning.

So the announcement sets day 0 for the backlog, and anything appearing later
starts from its own first sighting. A run started today reports the whole
backlog as `backlog: true` with the full grace period still ahead of it, while
`finding_age_days` still shows the true age for context.

A group is anchored on its **oldest** open finding. A rule that keeps producing
new alerts must not have its clock reset by each one, or a sporadic rule would
never become overdue at all.

Nothing is stored between runs. The countdown is recomputed from the API on
every run, so there is no ledger to drift or lose.

### A warning you will probably see on a first run

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

The three above are all the **digest** needs. Everything below is required only
by the `send` job; without it the digest runs exactly as before.

## Setting up sending

### 1. Create the `grace-warning-send` environment

**Settings → Environments → New environment**, named exactly
`grace-warning-send` (the job references it by name; a typo means the job waits
forever for an environment that does not exist).

Then, on that environment:

- **Required reviewers** — add at least one person. **This is the whole point
  of the environment.** An environment with no reviewers does not pause; the
  job runs straight through and the approval gate silently is not one.
  Add someone other than the usual dispatcher if you can — a reviewer who is
  always the person who clicked "Run workflow" is a rubber stamp.
- **Deployment branches** — restrict to your default branch, so the send path
  cannot be run from an unreviewed branch.

The repo already has a `test-tenant` environment (workflows 1, 2 and 9) — this
is the same mechanism, deliberately under a different name. `test-tenant` gates
*writes to the tenant*; this one gates *contacting humans*. Different blast
radius, different reviewers, so they should not share a gate.

### 2. Add the five SMTP secrets

Repository (or environment) secrets:

| Secret | Example | Notes |
|---|---|---|
| `SMTP_SERVER` | `smtp.sendgrid.net` | Hostname only, no scheme, no port |
| `SMTP_PORT` | `587` | See the port note below |
| `SMTP_USERNAME` | `apikey` | Provider-specific — often a literal, not your address |
| `SMTP_PASSWORD` | *(token)* | An API key or app password, **not** a login password |
| `SMTP_FROM` | `prisma-campaign@…` | The envelope sender; must be one the relay is allowed to send as |

Putting them on the **environment** rather than the repository is stricter: they
then exist only for jobs that have passed the approval gate, so nothing else in
the repo can read them even by accident. The workflow reads them the same way
either way.

### ⚠️ Which relay — the part that needs a decision

**A corporate relay that authorises by source IP will not work here.** A
GitHub-hosted runner is an arbitrary cloud address that changes every run, so
there is nothing to allowlist. The relay has to authenticate with the
*credentials* above. That rules out most internal "just relay from our subnet"
servers unless they also accept SMTP AUTH from outside.

Realistic options, in order of least friction **for this domain**:

1. **A personal Gmail account with an App Password** — the recommended
   starting point. See the next section. (The corporate Workspace account
   would be tidier, but App Passwords are **disabled by admin policy** on
   `paloaltonetworks.com` — confirmed, and not something you can override.)
2. **A transactional provider** (SendGrid, Mailgun, Amazon SES, Postmark).
   Credential auth, works from anywhere, free tiers cover this volume. Like
   Gmail, `SMTP_FROM` must be a domain it is authorised for — **not**
   `@paloaltonetworks.com`, whose SPF its IPs fail (measured below) under
   DMARC `p=reject`. The right long-term answer, not the quickest first send.
3. **An internal relay that accepts authenticated submission from the
   internet.** The only route that can legitimately send *as* the work
   domain. Best deliverability, most paperwork.
4. **A self-hosted runner inside the network**, if an IP-authorised relay is
   the only option. This changes where the job runs, not what it does.

> [!NOTE]
> **Port 25 is blocked on GitHub-hosted runners**, so a relay that only
> listens there is unreachable from here. Use `587` or `465`.
>
> Both are supported and both are tested: the send step uses `SMTP_SSL` for
> `465` (implicit TLS, encrypted from the first byte) and `SMTP` +
> `starttls()` for everything else. Writing this section is what exposed
> that only `587` worked — the step called `starttls()` unconditionally, so
> `465` could only ever fail. Rather than document the trap, it was fixed,
> and both paths are now exercised against a real local SMTP server that
> asserts on the delivered envelope.

**Not the Prisma Cloud tenant.** Measured: `/settings/smtp` returns 404 on this
tenant, so there is no relay to borrow. Mail leaves from the runner or not at
all.

### Sending via Gmail

Use a **personal** Gmail account. A corporate Workspace account is the
tidier-looking option but App Passwords are commonly disabled by admin policy
there — measured on this domain: **disabled**, and that is not something you
can work around from your side.

| Secret | Value |
|---|---|
| `SMTP_SERVER` | `smtp.gmail.com` |
| `SMTP_PORT` | `587` |
| `SMTP_USERNAME` | `you@gmail.com` (personal account, full address) |
| `SMTP_PASSWORD` | a **16-character App Password** — see below |
| `SMTP_FROM` | the *same* address as `SMTP_USERNAME` |

⚠️ **`SMTP_FROM` must be the Gmail address, not your work address.** Gmail
only lets you send as an address you have verified; set anything else and it
either rewrites the header or refuses. The *recipient* stays the pinned work
address — mail simply arrives from your personal account, which for a test
campaign is honest labelling rather than a defect.

#### Why this combination is the one that works

Three separate policies have to line up, and they were checked rather than
assumed (2026-08-21):

| Domain | Role | Policy | Consequence |
|---|---|---|---|
| `paloaltonetworks.com` | **From**, if you send as work | SPF per-IP macro, `-all`, DMARC **`p=reject`** | Only pre-authorised IPs may send. A mismatch is **rejected**, not junked. |
| `gmail.com` | **From**, as configured above | `redirect=_spf.google.com` (`~all`), DMARC **`p=none`** | Google's own submission path is authorised; nothing to arrange. |
| `paloaltonetworks.com` | **To** | MX → Proofpoint | Receives ordinary external mail all day. |

The work-domain SPF was expanded per source IP, with controls:

| Sending IP | Result |
|---|---|
| Google `209.85.220.41`, `209.85.128.28`, `74.125.82.41` | `ip4:<that IP>` → **PASS** |
| Azure/GitHub-runner `20.62.156.30`, `13.107.42.14` | generic fallback → **FAIL** |
| Controls `1.2.3.4`, `203.0.113.99` | same fallback → **FAIL** |

*(The controls are the point. Google IPs echoing back their own address could
have been a lookup that repeats any input; the bogus IPs returning a visibly
**different** record is what proves it discriminates.)*

Two things follow:

- **The runner must never talk to the world directly.** It hands the message
  to `smtp.gmail.com` over authenticated submission and Google sends it from a
  Google IP. Same message, different source IP, opposite outcome.
- **Do not set `SMTP_FROM` to a `@paloaltonetworks.com` address** unless the
  relay is genuinely authorised for it. With `p=reject` that is not a
  deliverability nuisance, it is a bounce.

#### Getting the App Password

Signed in to the **personal** Google account:

1. Turn on **2-Step Verification** — myaccount.google.com → Security. App
   Passwords do not appear until this is on; that is the usual reason the
   page seems to be missing.
2. Go to myaccount.google.com/apppasswords, name it `prisma-grace-campaign`,
   and copy the 16 characters.
3. Paste it as `SMTP_PASSWORD`. The spaces Google displays are cosmetic;
   paste without them.

Your normal password will **not** work, and "less secure app access" no longer
exists — an App Password is the only route.

> [!NOTE]
> **Why not the work account?** App Passwords are disabled by admin policy on
> `paloaltonetworks.com` (confirmed). That is a domain-wide setting, so there
> is nothing to retry or configure — a personal account is the way around it,
> and for a test campaign it is a perfectly reasonable one.

Worth knowing:

- **Sending limits** are ~500 recipients/day on a free account, far above this
  campaign's volume (the live tenant currently produces about 5 messages/day),
  but it is the ceiling if the tenant grows.
- **It may land in Spam.** Mail from a personal Gmail address into a
  Proofpoint-filtered corporate mailbox is exactly the shape of thing that
  gets scored. Check the spam folder before concluding the send failed — and
  read the run summary, which now reports what was *actually* handed to the
  relay. Those are two different questions, and only the second one is about
  this workflow.
- **Enabling 2SV on a personal account is not reversible without effort**, and
  the App Password is a real credential to your mailbox. Keep it scoped to
  this use and revoke it when the test phase ends.

> [!IMPORTANT]
> Fine for proving the pipeline; not how the campaign should run for real.
> The mail comes from a person rather than a team, it breaks when you rotate
> the App Password, and a personal credential sits in repository secrets.
> Move to a service mailbox or a transactional provider before anything is
> addressed to real owners.

### 3. Prove it with the smallest possible send

Do not make the first run a real campaign run. In order:

1. Dispatch with `plan_warnings` on and `send_warnings` **off**. Read the
   summary: `emails_today` is the number of messages a send would produce.
   If that number surprises you, stop.
2. Download the artifact and read `warning_accounts[].recipient`. Every one
   must be the override address. (The run already fails if not — this is you
   checking the check.)
3. Re-dispatch with `send_warnings` on. Approve the environment. Every message
   goes to the override recipient, so the worst case is a small pile of mail in
   one inbox.
4. Read one. The body carries the real owners under `TEST MODE:` — that is the
   addressing you would be using for real, and this is the last cheap moment to
   discover it is wrong.

Only after that is it worth discussing sending to real owners, which is a
change to the pinned recipient and a separate conversation.

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

# Verification: auto-escalating policy rules from alert-only to blocking

Driven by this requirement:

> "For workload vulnerability policies (Deployed images vulnerability policy),
> each policy rule has an Alert and a Blocking option. The initial policy applied
> to a newly created collection will always start with alert-only policy rules,
> but we'd like to upgrade this to blocking if a critical alert goes unresolved
> for a period of time (for example, 14 days)."

Everything below was measured against the live tenant. Findings are tagged
**[product]** (behaviour of Prisma Cloud, portable to any tenant) or
**[tenant]** (contents of this specific lab, **not** predictive of a customer).

The lab is an immature, heavily-tested environment. Its *statistics* say nothing
about what a customer will do; its *API shapes* are still authoritative.

---

## 1. The headline: `graceDays` already exists — for vulnerability policies

**[product]** Every rule in the deployed-images vulnerability policy carries a
native grace timer. The escalation knob is:

```json
{ "alertThreshold": { "disabled": false, "value": 9 },
  "blockThreshold": { "enabled": true,  "value": 9 },
  "graceDays": 14 }
```

`graceDays` means exactly the requested behaviour: block, but not until the
finding has gone unfixed for N days. Evaluated continuously by Compute, per
image and per CVE.

**[tenant]** Already in use: `Test-KK` graceDays 10, `KishorePrismaRule` 30,
`jjeanclaude-deployed-grace-period` 1.

Severity scale confirmed from live rules: **1** low, **4** medium, **7** high,
**9** critical (`FMStopHighVulns` = 7, `Chris-Vulnerability-Rule` = 9).

**Consequence:** for vulnerability policies, do **not** build a state-tracking
runner. Set `graceDays: 14` at rule-creation time and the rule is born with the
fuse. No cron, no stored history, no drift.

`effect` is a **computed display string** (`"alert"` vs `"alert, block"`), not an
input. Do not write to it.

### Provider cannot express this

**[product]** `prismacloudcompute_image_vulnerability_policy` exists, but its
rule schema is:

```
block_message, collections, disabled, effect, grace_days, name, notes,
only_fixed, verbose
```

No `blockThreshold`, no `alertThreshold`. The provider's flat `effect` string
does not match the API's `blockThreshold {enabled, value}` structure.

It is also a **singleton** (`{_id: "containerVulnerability", policyType,
rules[79]}`), so any write is a read-merge-write over all rules — the same hazard
[`merge_apply.sh`](../terraform/modules/compute-runtime-policies/scripts/merge_apply.sh)
already solves for runtime policies. A resource declaring a subset risks
clobbering the rest.

**Conclusion:** script path, not the provider resource.

---

## 2. Runtime policies have NO grace concept — and cannot trivially get one

**[product]** Regex-scanned the full 546 KB / 145-rule container runtime policy
for `graceDays`, `threshold`, and `grace`: **all three absent.** Complete key
union across every rule:

```
advancedProtectionEffect, cloudMetadataEnforcementEffect, collections,
customRules, disabled, dns, filesystem, kubernetesEnforcementEffect, modified,
name, network, notes, owner, previousName, processes, skipExecSessions,
wildFireAnalysis
```

**Why it does not exist — this is semantic, not a missing feature:**

| | Vulnerability policy | Runtime policy |
|---|---|---|
| finding is | **state** (CVE present until patched) | **event** (happened at a timestamp) |
| "resolved" means | CVE gone from image | *undefined* |
| escalation knob | `blockThreshold {enabled,value}` | none |
| effect shape | one per rule | **~15 independent knobs** |

Grace days answer "you have had 14 days to patch this CVE." A runtime rule has
no equivalent — `processes.cryptoMinersEffect` is not a defect someone fixes, it
is a behaviour you allow or block.

### "Upgrade to blocking" is not one switch

**[tenant]** Effect distribution across 145 container rules — note `block` and
`prevent` are distinct values used differently per knob:

```
advancedProtectionEffect:      alert 135, block 2, disable 5, prevent 3
processes.defaultEffect:       alert 130, prevent 15
processes.cryptoMinersEffect:  alert 124, block 2, disable 8, prevent 11
network.defaultEffect:         alert 142, block 3
dns.defaultEffect:             alert 145   <- nothing blocks DNS anywhere
filesystem.defaultEffect:      alert 137, prevent 8
```

Any escalation must name **which knobs** to flip. That is a policy decision, not
a default. Blast radius is far higher than vuln blocking:
`processes.defaultEffect: prevent` kills unrecognised processes in running
containers.

---

## 3. Audits vs incidents — both come from runtime rules, but differ

**[product]** An **audit** is one raw detection. An **incident** is Compute's
correlation layer above audits, grouping them into an attack narrative.

Both originate from runtime policy rules: every incident embeds its source
audits (`audits[]`, 1–2 each, never zero) and each carries a `ruleName` that
resolves to a real runtime rule.

They are **distinct objects**: comparing IDs, overlap is **0** (100 standalone
audit IDs vs 101 incident-embedded audit IDs).

| | Audits | Incidents |
|---|---|---|
| state | none — pure event | `acknowledged` |
| identity | distinct IDs, no recurrence | stable, resolvable |
| policy scope | per-policy endpoint | both, tagged via `type` |
| supports a countdown | **no** | **yes** |

### ⚠️ Incidents span BOTH runtime policies

**[tenant]** `type`: container 63, host 37. `pavila-runtime-test` and `rp-lab`
are **host** rules (79 host rules exist), not container.

**[product]** `OT-WildFire-Demo-Rule` exists in **both** policies — a real name
collision. **A digest must key on `type` + `ruleName`**, never `ruleName` alone,
or it will escalate against the wrong policy.

### Routing key

**[product]** `.collections` on an incident is **not** a routing key — it lists
every collection the resource matches (**[tenant]** avg 168, min 153, max 200).
Routing on it notifies everyone.

The usable grouping is `accountID` + `type` + `ruleName`.

---

## 4. Aging: use the server-side filter, not snapshot diffing

**[product]** The CSPM alerts API answers "still open after N days" directly:

```
timeType=absolute & startTime=0 & endTime=<now - 14d> & alert.status=open
```

Verified: returned 6,690 open criticals, **all** with `firstSeen` older than the
cutoff, ages 14–398 days. `alertTime == firstSeen` on 50/50 rows.

Compute incidents support the same idea via `from`/`to` (verified: all returned
rows ≥14 days, 14–70 day range).

**This removes the need for durable history**, which matters because this repo
has **no Terraform backend** — there is nowhere safe to persist state (see
[`workflow-roadmap.md`](workflow-roadmap.md) "The state problem"). It is also
correct on the first run, whereas diffing cannot produce a 14-day answer until
it has run for 14 days.

### `lastSeen` is NOT a recurrence signal

**[product]** `lastSeen == firstSeen` on 100/100 open incidents; staleness
identical to age (19–425 days). It does not advance when a finding recurs, so
every open incident looks equally stale. Do not build on it.

---

## 5. Alert resolution reasons

**[product]** Seven distinct values observed across an 8,000-row sample
(2,000 per status). Treat as *observed, not exhaustive* — handle unknowns.

| status | reason | count **[tenant]** |
|---|---|---|
| resolved | `RESOURCE_DELETED` | 1,986 |
| | `RESOURCE_UPDATED` | 14 |
| dismissed | `USER_DISMISSED` | 1,977 |
| | `RESOURCE_LIST_DISMISSED` | 23 |
| open | `NEW_ALERT` | 1,428 |
| | `SCHEDULED` | 473 |
| | `RESOURCE_UPDATED` | 98 |
| | `POLICY_UPDATED` | 1 |
| snoozed | *(0 rows — status exists, unused here)* | — |

**[product]** `history[]` exposes a `pending_resolution` state that never appears
as a queryable status. Do not assume open/resolved/dismissed/snoozed is the
complete set.

`RESOURCE_UPDATED` drives transitions **both ways** — resolutions and re-opens
(**[tenant]** 388 vs 441 in history). A resource change can resolve an alert and
later reopen it.

### Why "not open" is a poor discharge condition

`RESOURCE_DELETED` dominates, and in a container estate it is the *least*
meaningful outcome: the pod is replaced, the alert closes, the same image
redeploys tomorrow as a new alert with a **new ID and a fresh clock**.

**Therefore: key any countdown on `imageID` + `type` + `ruleName`, not alert
ID**, or pod churn silently resets the timer.

### ⚠️ TRAP: `alert.reason` is not a filter

```
alert.reason=RESOURCE_DELETED     -> 18,350,398
alert.reason=TOTALLY_FAKE_REASON  -> 18,350,398
(no filter)                       -> 18,350,398
```

Silently ignored. Filter by reason **client-side after fetching**.

---

## 6. Exception mechanisms — they exist, in Compute

**[product]**

| Layer | Exception mechanism | Expiry? |
|---|---|---|
| CSPM policy (`workload_incident`) | **none** — `rule` is only `{name, type}` | — |
| Compute vuln policy | `cveRules[]` | **yes, native** |
| Compute runtime rules | `processes/filesystem.allowedList`, `network.allowedIPs`, `dns.domainList` | **no** |

`cveRules` is the strongest instrument available and is exactly the
"add it to the ignore list" workflow:

```json
{ "id": "CVE-2021-44228", "effect": "ignore",
  "description": "test-for-solace",
  "expiration": { "enabled": true, "date": "2026-06-24T18:30:00Z" } }
```

Scoped to a CVE, carries a description, **expires on a date**, and lives in the
policy where this repo can manage it as config.

**[tenant]** `cveRules` used by 14/79 vuln rules; allow-lists by 31/145 runtime
rules (e.g. `/app/aws-k8s-agent`).

**Gap:** runtime allow-lists have **no expiry field** — permanent until someone
edits them. If recommended as the false-positive path, the review cadence must
come from us (e.g. a digest line "N allow-list entries, oldest added X ago").

**Unverified:** whether an alert actually reappears after `cveRules.expiration`
passes. Test before relying on it as self-healing.

---

## 7. Dismissal and RBAC

**[product]** Dismissal always records `dismissedBy` and `dismissalNote` — it is
an attributable act, not an anonymous click.

**[product]** `dismissalUntilTs = -1` is a **sentinel meaning "never expires"**,
not a timestamp. The product permits permanent dismissal; expiry is optional.
(Corrected during research: treating `-1` as a date yields a nonsense
"-20,677 days".)

**[product]** Dismissal is a **separately grantable permission**. Feature grants
live on the permission-group **detail** object
(`GET /authz/v1/permission_group/{id}` — 109 features), not the list:

| feature | operations |
|---|---|
| `alertsSnoozeDismiss` | `UPDATE` |
| `alertsRemediation` | `UPDATE` |
| `computeManageAlerts` | `UPDATE`, `READ` |
| `alertsAlertRules` | CRUD |

`prismacloud_permission_group` has a `features { feature_name }` block, so this
**is expressible in Terraform** via the existing rbac module. "Only reviewers may
dismiss" is an enforceable access control, not just a policy request.

---

## 8. Notification channels

**[product]** Compute **alert profiles** support 12 channels: `email`, `slack`,
`jira`, `serviceNow`, `pagerduty`, `splunk`, `cortex`, `securityHub`,
`securityCenter`, `gcpPubsub`, `sqs`, `webhook`. Each trigger (27 of them,
including `containerVulnerability`) carries `{enabled, allRules, rules[],
cloudServicesScope}` — so **per-collection scoping already exists**.

**[product]** CSPM **alert rules cannot be externally triggered.** Their schema
is `notifyOnOpen / notifyOnResolved / notifyOnDismissed / notifyOnSnoozed` —
every trigger is an alert lifecycle transition. "Unresolved for 14 days" is not a
transition, so there is no hook.

**[product]** `POST /api/v1/alert-profiles/test` returns **HTTP 200 with an empty
body even for a profile that does not exist** — no validation, no delivery
signal. Not usable as a trigger. No generic ingest exists either (`/events`,
`/alert-profiles/notify`, `/audits/custom` all 404).

**Consequence:** use alert-profile channel definitions as the **routing table**,
but send the digest from the runner.

**[product]** No tenant-wide SMTP relay endpoint (`/settings/smtp`,
`/settings/email` → 404). SMTP is **per-profile**: `smtpAddress` + `port` +
`credentialId` referencing a `basic` credential. **[tenant]** Proven working by
`jbrox-vulnerability-smtp-email-notification` → `smtp.web.de:587`.

### Owner resolution

**[tenant]** Sampled 300 images:

| signal | coverage |
|---|---|
| resolvable cloud account | 289 / 300 |
| in a named collection | 300 / 300 |
| has namespace | 131 / 300 |
| **has any owner/team/contact label** | **0 / 300** |

**No owner is derivable from image metadata.** The recipient mapping must be
declared by us — `teams.yaml` already maps teams to `account_ids`; add a
`notification_email` / channel per team. `Non-onboarded cloud accounts` needs a
fallback recipient.

**[product]** `GET /api/v1/images` **caps `limit` at 100** (`limit=500` → HTTP
400, no partial data). Must page.

---

## 9. Recommended shape (not yet built)

> **Workflow numbering updated 2026-08-12.** Workflow 7 is now the shipped
> `compute-alert-summary`. The digest below is **workflow 8** and the gated
> escalator is **workflow 9**.

Separate workflows — workflow 6 stays read-only and safe to run at will; these
send mail and eventually change enforcement.

```
Workflow 6 (alert-summary, unchanged)  --artifact--> context/enrichment only
Workflow 8 (grace-digest, scheduled)   --> promoted workload_incident alerts
                                       --> group by auditRuleName + type + account
                                       --> count occurrences in the window
                                       --> resolve account -> team -> channel
                                       --> emit escalation-candidates.json
Workflow 9 (runtime-escalate, GATED)   --> read-merge-write, named knobs only
```

> ### ⚠️ CORRECTED 2026-08-12 — the claim below was WRONG
>
> It previously read: *"The alert artifact cannot be the trigger… they carry no
> `acknowledged` and no `ruleName`… Workflow 7 must query Compute directly."*
>
> **The `ruleName` half is false.** With `detailed=true`, every promoted
> `workload_incident` alert carries a `metadata` block containing
> **`auditRuleName`** — the runtime rule — on **50/50** sampled alerts.
>
> The error: I searched for Compute's field name (`ruleName`) at the top level.
> CSPM **renames** it to `auditRuleName` and nests it under `metadata`. Same
> class of mistake as `nextPageToken` vs `pageToken` — a renamed field read as
> an absent one. Grep the whole payload before concluding a field is missing.

**The promoted alert is the source of truth** (decided with the requester: the
customer environment promotes runtime incidents by design, because the policies
are configured that way).

`metadata` on a promoted `workload_incident` alert — coverage out of 50 sampled:

| field | coverage | use |
|---|---|---|
| `auditRuleName` | 50/50 | **the runtime rule** — the escalation target |
| `auditCount` | 50/50 | **occurrence count** — the recurrence signal |
| `lastIncidentTime` | 50/50 | advances on recurrence (unlike the inert `lastSeen`) |
| `auditTime`, `auditType`, `incidentCategory` | 50/50 | when / what kind |
| `auditMessage` | 50/50 | human-readable detail for the digest |
| `auditUser`, `auditAttackTechniques` | 44/50, 43/50 | actor, MITRE mapping |
| `cveCritical/High/Medium/Low` | 50/50 | vulnerability context on the same object |

This gives **one API and one auth path** — the same `/v2/alert` endpoint
workflow 6 already uses — plus the full CSPM lifecycle (`dismissedBy`,
`dismissalNote`, `dismissalUntilTs`, `history[]`) that the discharge rule
depends on. The raw Compute incident has none of that: `acknowledged` is its
only state field, and it records no actor, no note and no expiry.

### Promotion is one-to-one, not aggregation [product]

`auditCount` is **1 on 99 of 100** sampled alerts (max 2, sum 101). A promoted
alert corresponds to an incident; it does not roll many into one.

**[tenant]** The sandbox holds 341 promoted alerts against 14,410 Compute
incidents dating back to Jan 2024, and its newest promoted alert lagged the
newest incident by ~13 days. Recorded as a lab artifact of an unmaintained
environment, **not** as product behaviour. But if a customer digest ever looks
implausibly quiet, re-check this first — it is the assumption whose failure
would hide a live problem.

### Discharge rule (decided)

Evaluated against the **promoted alert**, which is what carries these fields.

| signal | effect |
|---|---|
| `RESOURCE_UPDATED` | clears grace |
| active `cveRules` ignore | clears grace |
| dismissal **with** expiry (`!= -1`) | clears until expiry, then resumes |
| dismissal **permanent** (`-1`) | does **not** clear; flagged in digest |
| `RESOURCE_DELETED` | does not clear (key on image+rule) |

Rationale: the test is not "did a human act" but **"is the acceptance
bounded?"** A dismissal with an expiry returns for review; a permanent one never
does.

Make this **configurable per team** in `teams.yaml` rather than hard-coded — a
mature team may earn looser terms; a new one should not get them by default.

### Measure RECURRENCE, not age (decided 2026-08-12)

The original ask was "escalate if unresolved for 14 days." For a *vulnerability*
that is coherent — the CVE is present until patched. For a runtime *event* it is
not: the event happened, and **no API call makes it un-happen**. There is no
"resolved" state on a runtime incident to age against.

**[product]** Incidents are timestamped events that never close and never age
out of the store, so "older than N days" trends toward *everything ever
recorded* in any long-lived tenant. Age therefore measures **whether anyone
clicked**, not whether the risk persists. (Observed in the sandbox: 14,398 of
14,410 incidents were already older than 14 days. The ratio is **[tenant]**; the
mechanism producing it is **[product]**.)

The digest instead groups by **`auditRuleName` + `type` + account** and reports
rules **still producing incidents** inside the window, with occurrence counts.
A fixed workload stops firing, so the signal clears itself — which means the
report-only stage needs no discharge vocabulary at all.

### ⚠️ Workflow 9 must stay human-gated (confirmed with requester)

For vuln policies, `graceDays` is enforced by the **platform** — if our runner
dies, blocking still happens on day 14. For runtime, **the runner IS the
enforcement**. A week of silent failures means either a deadline that never
arrives, or blocking with no warning sent. Keep the flip gated and make the
digest fail loudly (`if: failure()`, per workflow 6's pattern).

### ⚠️ TRAP on the incidents endpoint

```
acknowledged=true     -> Total-Count 86
acknowledged=garbage  -> Total-Count 86     <- silently returns the =true set
acknowledged=false    -> Total-Count 14,320
totallyFakeParam=zzz  -> Total-Count 14,409 <- unknown params ignored entirely
```

Same silent-ignore class as the CSPM alerts API. Assert the filtered count
differs from the unfiltered baseline.

### Compute incidents endpoint — mechanics confirmed 2026-08-12 [product]

Recorded even though the digest reads CSPM, because the escalator (workflow 9)
will need the Compute side.

| Behaviour | Detail |
|---|---|
| `limit` | **caps at 100**; `limit=200` → HTTP 400, same as `/images` |
| `offset` | **works** — walks the full set |
| `page` | **silently ignored** — returns page one. Another rename trap |
| `from=` / `to=` | honoured; a 14-day `to=` yielded a set with min age exactly 14d |
| `type=` | honoured; `type=BOGUS` → 0 (fails closed) |
| Token lifetime | **short** — both CSPM and Compute tokens expired mid-spike. Long runs must re-authenticate rather than assume an empty result means "no data" |

### Only ONE incident write route exists [product]

Probed with a valid-shaped but nonexistent ObjectId, so nothing real was
touched. The real route returns a *specific* error; absent routes return an
empty 404:

```
PATCH /audits/incidents/acknowledge/{id}  -> {"err":"incident ... not found"}  ROUTE EXISTS
PATCH /audits/incidents/{unacknowledge|dismiss|resolve|archive|note}/{id} -> 404 empty
PUT | PATCH | DELETE /audits/incidents/{id}                               -> 404 empty
```

**There is no dismiss, resolve, archive, note or unacknowledge route for a
Compute incident.** Acknowledgement is also **unattributed**: a field-by-field
diff of acked vs unacked incidents shows identical schemas — no `acknowledgedBy`,
no timestamp, no note. Contrast CSPM dismissal, which always records
`dismissedBy` + `dismissalNote`.

This is the concrete reason the promoted alert wins: **"who accepted this risk,
and why?" is unanswerable from the Compute incident object.**

---

## Open questions

1. **`graceDays` start-clock** — counts from CVE detection, or from fix
   availability? Decides whether 14 days is generous or nearly instant. One test
   rule settles it.
2. **`graceDaysPolicy`** — a second, per-severity mechanism
   (`{enabled: true, high: 1000}`). **[tenant]** only 2 rules use it. Precedence
   over flat `graceDays` is undocumented and untested.
3. **`cveRules` expiry** — does the finding actually reappear after the date?
4. **Runtime allow-list review** — no expiry exists; what cadence do we impose?
5. **Baseline before enforcement** — run the digest report-only for one cycle and
   measure the customer's real dismissal/remediation behaviour. Lab statistics
   are not predictive; this report is itself valuable to an immature customer.
6. **⚠️ Does Prevent/Block stop incident creation?** **Load-bearing and
   unverified.** If a blocked action still emits an incident, "still firing"
   never clears after escalation and the digest keeps nagging about a rule that
   is already fixed. Every audit sampled had `effect: alert`, which proves
   nothing in an alert-only tenant. **Settle before building workflow 9.**
7. **`auditRuleName: "default"`** — 15 of 100 promoted alerts carry it, and it is
   not one of the 145 named runtime rules (most likely the built-in learned
   model). It cannot be escalated by name, so it needs separate handling or
   explicit exclusion from the digest.

---

## Summary

| Question | Answer |
|---|---|
| Does a native grace timer exist? | **Yes** for vuln policies (`graceDays`); **no** for runtime |
| Build a 14-day state tracker for vulns? | **No** — set `graceDays: 14` at creation |
| Can the provider express the vuln change? | **No** — schema lacks `blockThreshold` |
| Can CSPM alerts drive escalation? | **Yes — corrected 2026-08-12.** Promoted `workload_incident` alerts carry `metadata.auditRuleName` + `auditCount`; they are the chosen source of truth |
| Age or recurrence? | **Recurrence** — incidents never close, so age trends toward "everything ever recorded" |
| Can a Compute incident be dismissed or resolved via API? | **No** — `acknowledge` is the only write route, and it records no actor, note or expiry |
| Audits or incidents for the countdown? | **Incidents** — audits have no resolvable state |
| Need durable history? | **No** — server-side age filters answer it directly |
| Do exception lists exist? | **Yes** in Compute (`cveRules` with expiry); **none** in CSPM |
| Can we restrict who dismisses? | **Yes** — `alertsSnoozeDismiss` is grantable via Terraform |
| Can alert rules be triggered externally? | **No** — lifecycle transitions only |
| Multi-channel routing? | **Yes** — 12 channels on Compute alert profiles |

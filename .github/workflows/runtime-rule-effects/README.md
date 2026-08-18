# Workflow 9 — Runtime Rule Effects (escalation)

Answers **"which firing rules are still only watching?"** — and, behind a
manual gate, turns one of them into a blocking rule.

**This is the only workflow in the repository that changes enforcement on a
live runtime security policy.** Run with the escalation fields blank and it is
a read-only report.

---

## Why "cannot" rather than "does not"

The plan job cannot write, structurally rather than by convention:

- the escalation runs in a **`null_resource` provisioner**, which only executes
  during `terraform apply`. A `data` source would have run during **plan** —
  that is the whole reason it is built this way.
- the plan job asserts afterwards that the plan would change nothing outside
  this module, and **fails the run** if it would.
- the workflow itself makes no API calls; it has no `curl` at all.

---

## An escalation targets a SITE, not a rule

This is the thing to understand before using it.

"Escalate this rule" is ambiguous: a container runtime rule carries **nine
independent effect sites**, a host rule a smaller and different set. There is no
single switch.

So you choose four things, and three of them come straight from the plan output:

| field | where it comes from |
|---|---|
| `escalate_kind` | `container` or `host` — from the candidates table |
| `escalate_rule` | the exact rule name — copy it |
| `escalate_site` | the site path, e.g. `processes.deniedList.effect` — **copy verbatim** |
| `escalate_effect` | `prevent`, or `block` for containers only |

They are four separate form fields rather than one pasted JSON blob on purpose:
a mistyped blob is a bad way to choose which rule starts blocking traffic.

---

## How to use it

### Step 1 — Run it read-only

Actions → **9. Runtime Rule Effects (escalation)** → Run workflow. Leave every
`ESCALATE:` field blank. Pick a window and an alert status.

You get a table of **escalation candidates**: sites still set to `alert` on
rules that keep firing.

### Step 2 — Pick one and copy its three values

From the candidates table. The `site` column is a literal path — copy it
exactly, including the dots.

### Step 3 — Run again with the fields filled and `confirm` = `APPLY`

All four escalation fields, plus the word `APPLY` in `confirm`. Typed exactly,
uppercase.

Filling in **some but not all four** fails the run on purpose. A half-filled
form is a mistake, not a request for a read-only run — silently reporting
"nothing requested" would be much worse.

### Step 4 — Approve the environment gate

The apply job waits on the `test-tenant` environment. Approving it runs a
**preflight** that re-reads live state and refuses if:

- the escalation status is no longer `will_apply`, or
- the target is no longer an alerting site — renamed, deleted, or already
  escalated by someone else.

Approving a gate does not re-validate a plan, which is exactly why the
preflight exists.

Only then does the write happen.

---

## Five things must line up before anything is written

1. a manual dispatch (there is **no** schedule or push trigger)
2. all four escalation fields filled
3. `confirm` typed as exactly `APPLY`
4. the `test-tenant` environment approved by a human
5. the script's own `APPLY` check, which it re-runs independently

Verified: `""`, `true`, `yes` and `apply` all leave the run read-only.

---

## The most likely misreading: escalation does NOT silence workflow 8

Effect and logging are **orthogonal settings**. Escalating changes enforcement,
not telemetry — a blocked action still records an incident by design.

**A rule that keeps appearing in the digest after you escalate it is working.**
If you read "still firing" as "the escalation failed", you will escalate it
again and change nothing.

The read-only report separates these for you:

| output | meaning |
|---|---|
| `alerting_sites` | still only watching — **the candidates** |
| `enforced_sites` | already blocking, and still firing — expected |
| `disabled_sites` | detection is **off** — not a candidate |

---

## `disable` is not a candidate, deliberately

`disable` is a fourth effect value (undocumented in the API pages consulted, and
the most common one in practice — 611 of 805 container values measured). It
means the detection is switched off.

`disable → prevent` therefore switches on a detection that was never running.
That is a much larger decision than `alert → prevent`, so it is listed
separately and the writer refuses it.

---

## `block` is container-only

A host rule rejects `block`; use `prevent`. This is caught at plan time rather
than as a mid-write API error.

---

## Some rules cannot be escalated at all

**The built-in `default` model has no rule object.** There is nothing to PUT.
Alerts attributed to `default` are reported separately.

`default` is also, in some tenants, a real rule name — so an alert naming it
cannot be assumed to have come from the built-in model.

---

## When the run fails on purpose

| message | meaning |
|---|---|
| `N of 4 escalation fields were filled in` | Provide all four, or none. |
| `The plan would change resources outside this module` | `-target` is not holding; an apply would touch something unrelated. |
| `Escalation status is 'X', not 'will_apply'` | The confirm word or the request changed between plan and approval. |
| `... is no longer an alerting site` | Renamed, deleted, or already escalated. Nothing was changed. |
| `block is not a valid effect for a host rule` | Use `prevent`. |

Every one of these stops **before** any write.

---

## Setup requirements

Repository secrets:

- `PRISMACLOUD_API_URL`
- `PRISMACLOUD_USERNAME` (access key id)
- `PRISMACLOUD_PASSWORD` (secret key)
- `PRISMA_COMPUTE_CONSOLE_URL` — **must include the path prefix**, e.g.
  `https://us-east1.cloud.twistlock.com/us-2-158320372`. Without it,
  authentication returns a 404 or an empty token.

A `test-tenant` environment with required reviewers. Without reviewers the
approval gate is decorative.

The credentials need **write** access to runtime policies for step 3. Read
access is enough for the report.

---

## Why it needs two APIs

The promoted CSPM alert carries **no `effect` field at any depth** (verified
across 100 alerts). Enforcement state lives only in the Compute Console policy
objects. So "which firing rules are still only alerting?" needs the alert stream
from CSPM joined to the rule state from Compute, by rule name.

---

## Relationship to workflow 8

Workflow 8 reports **recurrence** — which rules keep firing. It cannot see
enforcement state.

Workflow 9 adds enforcement state and the ability to change it.

They are a hand-off, not a pipeline: neither references the other, the join key
is the rule name, and escalation never removes anything from workflow 8's
output.

---

## More detail

- Module: [`terraform/modules/runtime-rule-effects/README.md`](../../../terraform/modules/runtime-rule-effects/README.md)
- Findings: [`plans/policy-escalation-findings.md`](../../../plans/policy-escalation-findings.md)

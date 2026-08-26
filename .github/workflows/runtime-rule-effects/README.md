# Workflow 9 — Runtime Rule Effects (escalation)

Reports **which firing rules are still only watching**, and — behind a manual gate — turns one of them into a blocking rule.

**The only workflow in the repository that changes enforcement on a live runtime security policy.** Run with the escalation fields blank and it is a read-only report.

## Structurally read-only unless armed

- The escalation runs in a `null_resource` provisioner, which only executes during `terraform apply` (a `data` source would run during plan).
- The plan job asserts the plan changes nothing outside this module, and fails the run if it would.
- The workflow makes no API calls itself — no `curl`.

## An escalation targets a SITE, not a rule

A container runtime rule carries 27 independent effect sites, a host rule 19 — no single switch. Four fields, three copied straight from the plan output:

| field | where it comes from |
|---|---|
| `escalate_kind` | `container` or `host` — from the candidates table |
| `escalate_rule` | exact rule name — copy it |
| `escalate_site` | site path, e.g. `processes.deniedList.effect` — copy verbatim |
| `escalate_effect` | `prevent`, or `block` for containers only |

Four separate form fields rather than one pasted blob.

## How to use it

### Step 1 — Run it read-only

Actions → **9. Runtime Rule Effects (escalation)** → Run workflow. Leave every `ESCALATE:` field blank. Pick a window and an alert status.

Returns a table of **escalation candidates**: sites still set to `alert` on rules that keep firing.

### Step 2 — Pick one and copy its three values

`site` is a literal path — copy it exactly, including the dots.

### Step 3 — Run again with the fields filled and `confirm` = `APPLY`

All four escalation fields, plus `APPLY` (exact case) in `confirm`. Filling in some but not all four fails the run.

### Step 4 — Approve the environment gate

Apply job waits on the `test-tenant` environment. Approval runs a **preflight** that re-reads live state and refuses if the escalation status is no longer `will_apply`, or the target is no longer an alerting site (renamed, deleted, already escalated).

Only then does the write happen.

## Five things must line up before anything is written

1. Manual dispatch — no schedule or push trigger
2. All four escalation fields filled
3. `confirm` typed as exactly `APPLY`
4. `test-tenant` environment approved by a human
5. The script's own independent `APPLY` check

Verified: `""`, `true`, `yes`, `apply` all leave the run read-only.

## Escalation does NOT silence workflow 8

Effect and logging are orthogonal — escalating changes enforcement, not telemetry. A blocked action still records an incident.

| output | meaning |
|---|---|
| `alerting_sites` | still only watching — the candidates |
| `enforced_sites` | already blocking, still firing — expected |
| `disabled_sites` | detection is off — not a candidate |

## `disable` is not a candidate

`disable` (611 of 805 container values measured) means detection is off. `disable → prevent` would switch on a detection that was never running — excluded on purpose, writer refuses it.

## `block` is container-only

Host rule rejects `block`; use `prevent`. Caught at plan time.

## Some rules cannot be escalated at all

The built-in `default` model has no rule object — nothing to PUT. `default` is also sometimes a real rule name, so an alert naming it can't be assumed to be the built-in model. Reported separately.

## When the run fails on purpose

| message | meaning |
|---|---|
| `N of 4 escalation fields were filled in` | Provide all four, or none. |
| `The plan would change resources outside this module` | `-target` isn't holding. |
| `Escalation status is 'X', not 'will_apply'` | Confirm word or request changed between plan and approval. |
| `... is no longer an alerting site` | Renamed, deleted, or already escalated. |
| `block is not a valid effect for a host rule` | Use `prevent`. |

## Setup requirements

- `PRISMACLOUD_API_URL`
- `PRISMACLOUD_USERNAME` (access key id)
- `PRISMACLOUD_PASSWORD` (secret key)
- `PRISMA_COMPUTE_CONSOLE_URL` — must include path prefix, e.g. `https://us-east1.cloud.twistlock.com/us-2-158320372`

`test-tenant` environment with required reviewers. Credentials need write access to runtime policies for step 3; read access is enough for the report.

## Why it needs two APIs

The promoted CSPM alert carries no `effect` field at any depth. Enforcement state lives only in Compute Console policy objects — the alert stream (CSPM) is joined to rule state (Compute) by rule name.

## Relationship to workflow 8

Workflow 8 reports recurrence; it can't see enforcement state. Workflow 9 adds enforcement state and the ability to change it. Neither references the other; join key is the rule name.

## More detail

- Module: [`terraform/modules/runtime-rule-effects/README.md`](../../../terraform/modules/runtime-rule-effects/README.md)
- Findings: [`plans/policy-escalation-findings.md`](../../../plans/policy-escalation-findings.md)

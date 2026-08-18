# runtime-rule-effects

Reports the **current enforcement effect** of runtime rules that are producing
alerts, and — behind a deliberate gate — raises one of them from `alert` to
`prevent`/`block`.

This is the module that answers the question workflow 8 cannot: *of the rules
that keep firing, which are still only watching?*

**It is the only module in this repository that changes enforcement on a live
runtime security policy.** Reading is unconditional; writing needs two separate
deliberate acts and never happens during `terraform plan`.

---

## The headline: an escalation targets a SITE, not a rule

"Escalate this rule" is not a well-formed instruction. VERIFIED against the
live tenant: a container runtime rule carries **27 independent effect sites**
and a host rule **19**, a different set. There is no single `effect` field to
flip.

> **Corrected 2026-08-18.** This said "nine", and so did the code — the site
> list was built from key names matching `Effect$` plus six hardcoded paths.
> Most effect fields are not spelled that way (`antiMalware.cryptoMiner`,
> `dns.intelligenceFeed`, `wildFireAnalysis`), so the report hid 2490 container
> and 1313 host settings sitting at `alert` or `disable`. Sites are now found by
> VALUE, which also picks up fields the vendor adds later.

So every escalation is addressed as four values:

| field | meaning |
|---|---|
| `kind` | `container` or `host` — which policy the rule lives in |
| `rule` | the exact rule name |
| `site` | a literal jq path into the policy object, e.g. `processes.deniedList.effect` |
| `effect` | the new value: `prevent` or `block` |

`site` is copied verbatim from the `alerting_sites` output. Nothing is inferred
and nothing is fuzzy-matched.

---

## Why this reads BOTH APIs

VERIFIED against 100 promoted alerts: **the CSPM alert carries no `effect`
field at any depth.** Enforcement state exists only inside the Compute Console
policy objects.

So answering "is this firing rule still only alerting?" requires:

1. the **alert stream** from CSPM — which rules are firing, and how often;
2. the **rule state** from Compute — what each rule's effect sites are set to;

joined by rule name. One API cannot answer it.

---

## The effect vocabulary differs by workload type

`block` is a **container-only** value. A host rule rejects it, so the module
refuses that combination at plan time rather than letting it fail mid-PUT:

```
`block` is not a valid effect for a host rule - use `prevent`.
```

---

## `disable` is a fourth value, and it is excluded on purpose

VERIFIED, and undocumented in the API pages consulted: `disable` is a fourth
effect value, and the most common one in practice (**611 of 805** container
values observed).

It means **the detection is off**. `disable → prevent` therefore switches on a
detection that was never running — a much larger and riskier decision than
`alert → prevent`. It is reported in its own `disabled_sites` output and is
never a candidate for escalation. The writer refuses to set it, too.

---

## Escalation does NOT silence workflow 8

Effect and logging are **orthogonal**. Escalating changes enforcement, not
telemetry: a blocked action still records an incident by design.

A rule that keeps appearing in the digest after being escalated is **working**,
not broken. Anyone reading "still firing" as "the escalation failed" is
misreading it. This is the single most likely misinterpretation of this module's
output.

---

## Requirements

- `terraform` >= 1.5 (uses `check` blocks)
- `jq` and `curl` on the runner
- Prisma Cloud credentials with read access to CSPM alerts and the Compute
  Console, plus **write** access to runtime policies if escalating

---

## Usage

Read-only (the default — writes nothing):

```hcl
module "runtime_rule_effects" {
  source = "./modules/runtime-rule-effects"

  enabled      = true
  window_days  = 14
  alert_status = "open"

  cspm_url    = var.prisma_cloud_api_url
  compute_url = var.prisma_compute_console_url
  access_key  = var.prisma_cloud_access_key
  secret_key  = var.prisma_cloud_secret_key
}
```

Escalating one site — note that **both** `escalations` and `apply_escalations`
are required:

```hcl
  escalations = [{
    kind   = "container"
    rule   = "my-runtime-rule"
    site   = "processes.deniedList.effect"
    effect = "prevent"
  }]

  apply_escalations = "APPLY"
```

---

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `false` | Read the tenant at all. |
| `window_days` | number | `14` | How far back to look for promoted alerts (1–3650). |
| `alert_status` | string | `"open"` | `open` \| `resolved` \| `dismissed` \| `snoozed`. Materially changes which rules appear. |
| `max_alerts` | number | `2000` | Cap on alerts fetched before grouping (1–10000). |
| `escalations` | list(object) | `[]` | Effect sites to escalate: `{kind, rule, site, effect}`. Empty writes nothing. |
| `apply_escalations` | string | `""` | Must be exactly `"APPLY"` to permit a write. |
| `cspm_url` | string | `null` | CSPM API host. |
| `compute_url` | string | `null` | Compute Console URL — **must include the path prefix**. |
| `access_key` | string | `null` | Shared across both APIs. |
| `secret_key` | string | `null` | Shared across both APIs. |
| `skip_cert_verification` | bool | `false` | Self-signed on-prem consoles only. |

---

## Outputs

| Name | Description |
|---|---|
| `status` | `ok` \| `disabled` \| `missing_credentials` \| `ambiguous_rules` \| `unmatched_rules` |
| `status_detail` | Human-readable explanation. Null when ok. |
| `summary` | Counts for the run. |
| `rules` | Every firing rule with its match status and site inventory. |
| `sites` | One row per effect site on every matched rule. |
| `alerting_sites` | **The escalation candidate list.** |
| `enforced_sites` | Already at prevent/block and still firing — expected, not broken. |
| `disabled_sites` | Detection is off. Not escalation candidates. |
| `ambiguous_rules` | Name exists in both policies. |
| `unmatched_rules` | Firing name with no live rule. |
| `builtin_rules` | Alerts attributed to `default`. |
| `scope` | What was actually queried. |
| `escalation_status` | `disabled` \| `nothing_requested` \| `not_confirmed` \| `will_apply` |
| `escalation_detail` | Human-readable explanation of the above. |
| `planned_escalations` | Exactly what an apply would write. |

---

## Callers must branch on `status`, not the exit code

The `check` blocks emit warnings, and **a failed check does not fail the plan.**
Worse, `terraform show -json` omits the `checks` array entirely for a plan file,
so a caller cannot detect the warning programmatically at all — it appears only
in human-readable stderr.

That is why `status` and `escalation_status` exist as outputs.

---

## The write path

### `terraform plan` never writes

The escalation runs in a `null_resource` provisioner, **not** a `data` source.
This is deliberate and load-bearing: a `data` source executes during **plan**,
so building the write that way would mean `terraform plan` — the command every
operator treats as safe — silently escalates live security policies.

VERIFIED on the live tenant: with an escalation staged *and* confirmed, a plan
reports one resource to create and changes nothing.

### Two independent conditions

Both must hold, and neither has a default that does anything:

1. `escalations` is non-empty — and is **never derived automatically** from
   `alerting_sites`. Auto-deriving would mean widening the alert window
   silently escalates more rules.
2. `apply_escalations` is exactly `"APPLY"`.

A word rather than a boolean, because `true` accumulates in CI defaults and env
files. VERIFIED: `""`, `true`, `yes` and `apply` all leave the module
read-only; only `APPLY` arms it.

### Credentials are not in `triggers`

Trigger values are stored verbatim in state. The access key and secret are
passed through the provisioner `environment` instead, which is not persisted.
The trigger holds a **sha256 of the requests only**, so rotating a key does not
re-trigger a policy write.

### The script refuses on its own

`scripts/apply_escalation.sh` re-checks everything the module checked, so it is
safe to run by hand and cannot be tricked by a caller that skipped a gate:

- `confirm` must be exactly `APPLY`
- `block` on a host rule is refused
- `disable` is refused
- an empty rule or site is refused
- **validation runs before any network call** — an earlier version
  authenticated first, so an unreachable console masked an invalid request
- the batch is **all-or-nothing**: one bad entry rejects every entry

### Re-derived from live state, not from the plan

The writer GETs the policy fresh, applies the change with `setpath` on the
literal jq path, and errors if the rule is missing, ambiguous, or the site does
not exist. It never replays a stale plan.

### Idempotency uses deep equality, not `cmp`

The pre-image is the server's raw response; the post-image is jq's
re-serialisation. Those differ in whitespace **even when nothing changed**, so a
byte comparison reports "changed" every time and the guard never fires — a
re-run would PUT an identical document back.

The check is therefore a jq deep comparison, which ignores key order but
respects array order (rule order is meaningful). Verified in both directions: an
identity transform, a key reorder, and a change-then-revert all read as
unchanged; an effect flip and an appended rule both read as changed.

---

## Guards

### Ambiguous rule names

A name can exist in **both** the container and host policies. The alert does not
say which one fired, so it is not resolvable from alert data. Sites are reported
per kind and an escalation must name the policy explicitly.

### Rules that no longer exist

Alerts outlive the rules that produced them. A firing name with no live rule is
reported in `unmatched_rules` rather than silently dropped.

### The built-in `default` model

`default` is both the built-in learned model's label and, in some tenants, a
real rule name — so an alert naming it cannot be assumed to come from that rule.
These are separated into `builtin_rules`. **The built-in model has no rule
object, so it cannot be escalated at all.**

---

## Credentials never touch `argv`

Everything is passed on stdin as JSON. Nothing sensitive appears in a process
listing.

---

## Verified against the live tenant

- the CSPM alert carries no `effect` field at any depth (100 alerts)
- `block` is container-only; a host rule rejects it
- `disable` is a fourth, undocumented value — 611 of 805 container values
- a container rule has 27 effect sites; a host rule has 19, a different set
- rule names DO resolve across the two APIs, but are not unique
- only `APPLY` arms the write; `""`, `true`, `yes`, `apply` do not
- `-target=module.runtime_rule_effects` isolates an apply to exactly 1 resource
  (without it, a confirmed run planned 4)

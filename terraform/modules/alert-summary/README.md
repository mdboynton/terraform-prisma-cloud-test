# alert-summary

Counts CSPM alerts scoped to a Collection, broken down by severity.

**This module is read-only by construction.** It contains only `data` blocks:

```bash
$ grep -rc "^resource" terraform/modules/alert-summary/*.tf
main.tf:0
outputs.tf:0
variables.tf:0
versions.tf:0
```

A plan against it always reports **0 to add, 0 to change, 0 to destroy**.

## Requirements

| Requirement | Version |
|---|---|
| Terraform | `~> 1.13` |
| `PaloAltoNetworks/prismacloud` | `1.7.1` |

## Usage

```hcl
module "alert_summary" {
  source = "./modules/alert-summary"

  enabled         = true
  collection_name = "phe-collection-test"
  alert_status    = "open"
  time_amount     = 30
  time_unit       = "day"
}
```

Normally you drive it through
[Workflow 6](../../../.github/workflows/alert-summary/README.md).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `enabled` | `bool` | `false` | Read alert counts. Off by default so other workflows pay nothing. |
| `collection_name` | `string` | `null` | CSPM Collection name, exactly as in the console. Required when enabled. |
| `alert_status` | `string` | `"open"` | `open` \| `resolved` \| `dismissed` \| `snoozed`. |
| `time_amount` | `number` | `30` | Lookback window size. |
| `time_unit` | `string` | `"day"` | `hour` \| `day` \| `week` \| `month` \| `year`. |
| `severities` | `list(string)` | all five | Severities to break down by. One query each. |

## Outputs

| Name | Description |
|---|---|
| `status` | `ok` \| `disabled` \| `collection_not_found` \| `ambiguous_collection_name` \| `repository_only` \| `tenant_wide`. **Branch on this.** |
| `status_detail` | Human-readable explanation. Null when `ok`. |
| `total` | Alert count for the collection. Null unless `status == "ok"`. |
| `by_severity` | Map of severity to count. |
| `tenant_total` | Tenant-wide count over the same window, for proportion. |
| `summary` | All of the above in one object. |
| `scope` | The account IDs actually queried, for troubleshooting. |

---

## Why this is not a one-line data source

**The alerts API has no collection filter.** Verified against the live tenant:
`GET /filter/alert/suggest` publishes 31 filter names and `collection` is not
among them.

So the module resolves the collection to its cloud accounts and filters by
those instead:

```
prismacloud_collections  ->  find id by name
prismacloud_collection   ->  asset_groups { account_ids, account_group_ids, repository_ids }
prismacloud_alerts       ->  one filters{} block per account id
```

A CSPM collection turns out to be nothing more than an `assetGroups` selector.
Across all 45 collections in this tenant the entire vocabulary is three keys —
there are no tag, cluster or namespace selectors that would translate lossily.

## The three findings this module is built around

### 1. An unknown filter name is silently ignored

This is the reason for every guard below. Measured:

| Query (open alerts, 30d) | Rows |
|---|---|
| *baseline* | 8818 |
| `collection=foo` | **8817** |
| `totallyBogusParam=xyz` | **8817** |
| `account.group=NoSuchAccountGroup` | 0 |

An unrecognised filter **name** is dropped and the request still returns HTTP
200 with the full tenant-wide result set. A naive implementation passing
`collection=<name>` would have reported ~8,800 alerts as the team's number, with
no error and a completely plausible-looking result.

A recognised filter with an unknown *value* correctly returns 0, so the hazard is
specific to names.

### 2. Comma-separated values silently return zero

```
account A alone            -> 188
account B alone            -> 271
repeated filters{} (A, B)  -> 459   = 188 + 271, correct OR
single filters{} "A,B"     ->   0   WRONG, and silently so
```

Hence the `dynamic "filters"` block emitting **one block per account**. Joining
with commas is the obvious-looking approach and would have under-reported every
multi-account collection to zero.

### 3. Alert Rules do not scope alerts

`alertRule.name` appears in the filter list, so scoping by the Alert Rule the
[`rbac`](../rbac/README.md) module creates looks natural. It returns nothing:

```
alerts carrying a non-empty alertRules array:   0 / 500
alerts carrying resource.cloudAccountGroups:  493 / 493
```

Alert Rules govern **notification routing**, not alert generation. A policy
evaluating a resource creates the alert; the rule decides who gets told. Cloud
account is the scope that works.

## Guards

| Guard | Behaviour |
|---|---|
| Collection name doesn't resolve | `status = collection_not_found`, `total = null` |
| Name matches 2+ collections | `status = ambiguous_collection_name`, `total = null` |
| Collection selects only repositories | `status = repository_only`, `total = null` |
| Collection selects `["*"]` (all accounts) | `status = tenant_wide`, `total = null` |
| Scoped total == tenant total | `suspect_unfiltered = true` (warning; can be legitimate) |
| Severity breakdown doesn't sum to total | `check` warning |

In every failure case `total` is **null**, never a tenant-wide number. That is
the whole point: a wrong answer that looks right is worse than no answer.

### Callers must branch on `status`, not the exit code

The `check` blocks emit warnings but **do not fail the plan** — a nonexistent
collection name still exits 0. Worse, `terraform show -json` omits the `checks`
array from a plan file entirely, so the failure is invisible to anything reading
plan JSON. Both behaviours were verified, and `status` exists because of them.

## Limitations

**Counts only.** `prismacloud_alerts.listing` exposes just `alert_id`, `status`,
timestamps and `triggered_by` — no resource, policy or severity fields. Severity
counts come from one query per severity, not from inspecting alerts.

Per-alert detail (resource names, policy names) would need direct API calls with
pagination. Deliberately deferred: the tenant holds ~8,800 open alerts at ~20 KB
each when detailed, roughly 180 MB of plan JSON, and a data source embeds its
whole result in the plan. `limit = 1` reads the server-side `total` without the
payload.

**Not suitable for drift detection.** Alert counts move constantly (8764 → 8920
over one session). They are deliberately excluded from
[`snapshot.sh`](../../../scripts/drift/snapshot.sh).

## Verified against the live tenant

| Collection | Status | Total | Tenant | Severities |
|---|---|---|---|---|
| `phe-collection-test` | `ok` | 491 | 8881 | 100/142/64/120/65 — sums to 491 |
| `collection-devsecops` | `ok` | 0 | 8920 | all zero (account genuinely has none) |
| `no-such-collection-xyz` | `collection_not_found` | null | — | — |
| `mdalbes-collection` | `tenant_wide` | null | — | — |

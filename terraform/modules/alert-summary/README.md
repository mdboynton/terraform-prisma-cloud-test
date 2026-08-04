# alert-summary

Counts CSPM alerts scoped to a Collection, broken down by severity, and
optionally lists the individual alerts with their policy and resource names.

**This module is read-only by construction.** It contains only `data` blocks:

```bash
$ grep -rc "^resource" terraform/modules/alert-summary/*.tf
main.tf:0
outputs.tf:0
variables.tf:0
versions.tf:0
```

A plan against it always reports **0 to add, 0 to change, 0 to destroy**.

The optional detail fetch does not weaken this: it uses `data "external"` — a
*data* source — and [the script](scripts/detail.sh) it runs only issues `GET`
requests.

## Requirements

| Requirement | Version |
|---|---|
| Terraform | `~> 1.13` |
| `PaloAltoNetworks/prismacloud` | `1.7.1` |
| `hashicorp/external` | `~> 2.3` (detail fetch only — a data source, not a resource) |

`bash`, `curl` and `jq` must be on PATH when `include_detail` is true.

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
| `include_detail` | `bool` | `false` | Also fetch per-alert detail. One extra paged call. Counts unaffected. |
| `detail_severities` | `list(string)` | `["critical"]` | Which severities to fetch detail for. |
| `detail_limit` | `number` | `500` | Cap on detail rows. Bounds runtime and plan size; never caps the counts. |
| `cspm_url` | `string` | `null` | API host. Required only when `include_detail` is true. |
| `access_key` | `string` | `null` | Required only when `include_detail` is true. Sensitive. |
| `secret_key` | `string` | `null` | Required only when `include_detail` is true. Sensitive. |

The three credential inputs exist because the detail script calls the REST API
directly and cannot read the provider's configuration.

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
| `detail_status` | `not_requested` \| `no_scope` \| `missing_credentials` \| `ok`. **Branch on this** — an empty row list is not the same as "no alerts". |
| `detail` | `{rows, fetched, total_matching, truncated, complete, stop_reason, max_rows, severities, by_severity}`. Null unless detail was fetched. |
| `detail_rows` | Just the rows, for rendering. Empty list rather than null when nothing was fetched. |

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

## Per-alert detail (opt-in)

`prismacloud_alerts.listing` exposes just `alert_id`, `status`, timestamps and
`triggered_by` — no resource, policy or severity fields. So detail comes from
[`scripts/detail.sh`](scripts/detail.sh) via `data "external"`, which is a *data*
source: the zero-resource guarantee above still holds, and the script only issues
`GET` requests.

Set `include_detail = true`. The counts are unchanged either way.

### Why the list endpoint, not `GET /alert/{id}`

The obvious endpoint is the wrong one. Measured on this tenant:

| Approach | Calls | Time | Payload |
|---|---|---|---|
| `GET /alert/{id}` per alert | 423 | **~27 min** | 3.3 MB |
| List, `detailed=true`, paged | 2 | **13.5 s** | 177 KB after reduction |
| List, `detailed=false` | 1 | ~1 s | **no `policy.name`, no `severity`** — unusable |

The list endpoint already carries every field the per-alert GET would return.
Verified: `policy.name`, `policy.severity`, `resource.name`,
`resource.resourceType`, `resource.id`, `resource.account`, `resource.regionId`
and `alertTime` were present on 100/100 rows.

### Reduction

A `detailed=true` row is ~9.3 KB, almost all of it `resource.data` (the full
cloud config blob). The script keeps eleven fields and drops the rest **per page,
before accumulating** — 263 bytes/alert, a 35× reduction. That is what makes it
safe for a data source, which embeds its whole result in the plan.

### Pagination

Token-based, and there is a trap. The response field is `nextPageToken`, but the
request parameter is **`pageToken`**. Sending `nextPageToken` back returns
HTTP 200 and **re-serves page one** — an infinite loop quietly collecting
duplicates. Same silent-ignore behaviour as the filters. The terminator is
`nextPageToken: null`.

Verified: 423 rows over 2 pages produced **423 unique ids**.

### Counts and detail are independent

`total` is always the server's count. `fetched` is how many rows came back under
`detail_limit`. A truncated fetch cannot make the collection look smaller —
verified with `detail_limit = 25` against 104 criticals:

| Field | Value |
|---|---|
| `summary.total` | 415 (unchanged) |
| `detail.fetched` | 25 |
| `detail.total_matching` | 104 |
| `detail.truncated` | `true` |
| `detail.stop_reason` | `cap` |

### `truncated` vs `stop_reason`

`truncated` means exactly one thing: **`total_matching > fetched`** — we do not
have every matching alert. It does *not* test the cap.

That distinction was a bug. The original condition also required
`fetched >= max_rows`, on the assumption that the cap is the only reason to stop
early. It isn't: stopping at 300 of 600 rows under a cap of 500 satisfies
neither clause, so `truncated` came out `false` and 300 missing alerts were
reported as a complete list.

`stop_reason` says *why* the list is short, so a deliberate cap is never
confused with a failure:

| `stop_reason` | Meaning |
|---|---|
| `complete` | The server had no more rows. Expected. |
| `cap` | `detail_limit` was reached, more exist. Expected — raise the limit. |
| `empty_page` | A page returned 0 rows while more were expected. Usually rate limiting. |
| `no_token` | The server stopped paginating early. Rows are missing. |
| `page_guard` | The 200-page ceiling tripped. |

Only the first two are normal. The workflow renders the last three differently,
saying explicitly that the shortfall was **not** the cap.

### The unscoped guard

The script **refuses to run** with an empty account list. An unscoped query would
not error — it would return all ~9,000 tenant alerts labelled as the
collection's. Same reason as every other guard here.

### Credentials never touch `argv`

The login body goes in on **stdin** (`curl --data @-`) and the bearer token via
**`-H @file`** from a `0700` temp dir removed by an `EXIT` trap.

This is not theoretical hygiene. The original `-d "{\"username\":...}"` form was
measured exposing the secret key to a plain `ps -o args=` on this machine, for
the life of the request. CI runners can host other processes. After the change,
sampling every 0.5s across a full run found the key in argv **0 times**.

The JSON body is built with `jq -n --arg`, so a credential containing a quote or
backslash cannot break out of the JSON — string interpolation would allow that.

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

Alert counts move constantly, so the totals above are a snapshot; the invariants
(sums, nulls, statuses) are what matter.

### Detail path

| Case | Result |
|---|---|
| `phe-collection-test`, critical | `fetched: 101`, matches the critical count exactly |
| `phe-collection-test`, all severities | 423 rows over 2 pages, **423 unique ids**, breakdown sums to 423 |
| `PCS-aws-org` (2,382 alerts, large) | 148 critical in **5.4 s**, no truncation |
| `detail_limit = 25` vs 101 criticals | `fetched: 25`, `total_matching: 101`, `truncated: true`, **`summary.total` unchanged at 415** |
| `include_detail = false` | **zero** detail API calls, `detail_status: not_requested` |
| Nonexistent collection | **zero** detail API calls, `detail_status: no_scope`, `total: null` |
| Empty account list (script directly) | Refused with an error, rather than returning tenant-wide alerts |

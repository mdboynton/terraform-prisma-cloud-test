# alert-summary

Counts CSPM alerts scoped to a Collection, broken down by severity; optionally lists individual alerts with policy/resource names.

Read-only: `data` blocks only, no `resource` blocks. Plan always 0 to add/change/destroy. Detail fetch uses `data "external"` with a script that only issues `GET`.

## Requirements

| Requirement | Version |
|---|---|
| Terraform | `~> 1.13` |
| `PaloAltoNetworks/prismacloud` | `1.7.1` |
| `hashicorp/external` | `~> 2.3` (detail fetch only) |

`bash`, `curl`, `jq` required on PATH when `include_detail` is true.

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

Normally driven through [Workflow 6](../../../.github/workflows/alert-summary/README.md).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `enabled` | `bool` | `false` | Read alert counts. |
| `collection_name` | `string` | `null` | CSPM Collection name, exact. Required when enabled. |
| `alert_status` | `string` | `"open"` | `open` \| `resolved` \| `dismissed` \| `snoozed`. |
| `time_amount` | `number` | `30` | Lookback window size. |
| `time_unit` | `string` | `"day"` | `hour` \| `day` \| `week` \| `month` \| `year`. |
| `severities` | `list(string)` | all five | Severities to break down by. |
| `include_detail` | `bool` | `false` | Fetch per-alert detail. Counts unaffected. |
| `detail_severities` | `list(string)` | `["critical"]` | Severities to fetch detail for. |
| `detail_limit` | `number` | `500` | Cap on detail rows. Never caps counts. |
| `cspm_url` | `string` | `null` | Required only when `include_detail` is true. |
| `access_key` | `string` | `null` | Required only when `include_detail` is true. Sensitive. |
| `secret_key` | `string` | `null` | Required only when `include_detail` is true. Sensitive. |

Credential inputs exist because the detail script calls the REST API directly and can't read the provider's config.

## Outputs

| Name | Description |
|---|---|
| `status` | `ok` \| `disabled` \| `collection_not_found` \| `ambiguous_collection_name` \| `repository_only` \| `tenant_wide`. Branch on this. |
| `status_detail` | Human-readable explanation. Null when `ok`. |
| `total` | Alert count. Null unless `status == "ok"`. |
| `by_severity` | Map of severity to count. |
| `tenant_total` | Tenant-wide count over the same window. |
| `summary` | All of the above in one object. |
| `scope` | Account IDs actually queried. |
| `detail_status` | `not_requested` \| `no_scope` \| `missing_credentials` \| `ok`. Branch on this. |
| `detail` | `{rows, fetched, total_matching, truncated, complete, stop_reason, max_rows, severities, by_severity}`. Null unless fetched. |
| `detail_rows` | Just the rows. Empty list rather than null when nothing was fetched. |

## Guards

The alerts API has no collection filter. Resolved instead via:

```
prismacloud_collections  ->  find id by name
prismacloud_collection   ->  asset_groups { account_ids, account_group_ids, repository_ids }
prismacloud_alerts       ->  one filters{} block per account id
```

| Guard | Behaviour |
|---|---|
| Collection name doesn't resolve | `status = collection_not_found`, `total = null` |
| Name matches 2+ collections | `status = ambiguous_collection_name`, `total = null` |
| Collection selects only repositories | `status = repository_only`, `total = null` |
| Collection selects `["*"]` (all accounts) | `status = tenant_wide`, `total = null` |
| Scoped total == tenant total | `suspect_unfiltered = true` (warning) |
| Severity breakdown doesn't sum to total | `check` warning |

An unrecognized filter **name** is silently dropped by the API (still HTTP 200, full result set); an unrecognized filter **value** correctly returns 0. Comma-joined multi-value filters silently return 0 — the module emits one `filters{}` block per account instead. `alertRule.name` scopes notification routing, not alert generation, and returns nothing (0/500 alerts carry a non-empty `alertRules` array) — cloud account is the scope that works.

### Callers must branch on `status`, not the exit code

`check` blocks warn but don't fail the plan, and `terraform show -json` omits the `checks` array entirely — `status` exists because of both.

## Per-alert detail (opt-in)

`prismacloud_alerts.listing` lacks resource/policy/severity fields, so detail comes from [`scripts/detail.sh`](scripts/detail.sh) via `data "external"` (GET only). Set `include_detail = true`; counts unchanged.

Uses the list endpoint with `detailed=true`, paged — not `GET /alert/{id}` per alert (423 calls / ~27 min vs. 2 calls / 13.5s for the same data). `detailed=false` omits `policy.name` and `severity`, making it unusable here.

### Reduction

A `detailed=true` row is ~9.3 KB (mostly `resource.data`). The script keeps eleven fields per page before accumulating — 263 bytes/alert, a 35× reduction, keeping the data source plan-safe.

### Pagination

Token-based. Trap: response field is `nextPageToken`, but the request parameter is `pageToken` — sending `nextPageToken` back re-serves page one silently (infinite loop, duplicate rows). Terminator is `nextPageToken: null`.

### Counts and detail are independent

`total` is always the server's count; `fetched` is rows returned under `detail_limit`. Truncation can't shrink `total`.

### `truncated` vs `stop_reason`

`truncated` means `total_matching > fetched` — nothing to do with the cap. `stop_reason` says why the list is short:

| `stop_reason` | Meaning |
|---|---|
| `complete` | Server had no more rows. |
| `cap` | `detail_limit` reached, more exist. |
| `empty_page` | Page returned 0 rows while more expected — usually rate limiting. |
| `no_token` | Server stopped paginating early. Rows missing. |
| `page_guard` | 200-page ceiling tripped. |

Only `complete`/`cap` are normal; the other three are surfaced as "NOT the cap."

### The unscoped guard

The script refuses to run with an empty account list — an unscoped query would otherwise return all tenant alerts labeled as the collection's.

### Credentials never touch `argv`

Login body via stdin (`curl --data @-`); bearer token via `-H @file` from a `0700` temp dir removed by an `EXIT` trap. JSON body built with `jq -n --arg` to prevent injection.

**Not suitable for drift detection** — alert counts move constantly, excluded from [`snapshot.sh`](../../../scripts/drift/snapshot.sh).

## Verified against the live tenant

| Collection | Status | Total | Tenant | Severities |
|---|---|---|---|---|
| `phe-collection-test` | `ok` | 491 | 8881 | 100/142/64/120/65 — sums to 491 |
| `collection-devsecops` | `ok` | 0 | 8920 | all zero |
| `no-such-collection-xyz` | `collection_not_found` | null | — | — |
| `mdalbes-collection` | `tenant_wide` | null | — | — |

### Detail path

| Case | Result |
|---|---|
| `phe-collection-test`, critical | `fetched: 101`, matches critical count |
| `phe-collection-test`, all severities | 423 rows over 2 pages, 423 unique ids |
| `PCS-aws-org` (2,382 alerts) | 148 critical in 5.4s, no truncation |
| `detail_limit = 25` vs 101 criticals | `fetched: 25`, `total_matching: 101`, `truncated: true`, `summary.total` unchanged at 415 |
| `include_detail = false` | zero detail API calls, `detail_status: not_requested` |
| Nonexistent collection | zero detail API calls, `detail_status: no_scope`, `total: null` |
| Empty account list (script directly) | Refused with an error |

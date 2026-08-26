# Workflow 6 — Alert Summary (read-only)

**Workflow file:** [`../alert-summary.yml`](../alert-summary.yml) · **Actions name:** `6. Alert Summary (read-only)`

Total alerts for a collection, a severity breakdown, share of tenant, and optionally individual critical alerts with policy/resource names.

**Can it change the tenant?** No — `data` blocks only, zero `resource` blocks, no apply job.

## How to use it

1. **Actions** → **6. Alert Summary (read-only)** → **Run workflow**
2. Type the **collection_name** exactly as it appears in the console
3. Optionally change status and window
4. **Run workflow**

| Input | Default | Notes |
|---|---|---|
| `collection_name` | *(required)* | Must match exactly. |
| `alert_status` | `open` | `open` \| `resolved` \| `dismissed` \| `snoozed` |
| `time_amount` | `30` | Window size |
| `time_unit` | `day` | `hour` \| `day` \| `week` \| `month` \| `year` |
| `include_detail` | `true` | Also list individual alerts. Adds one paged API call. |
| `detail_severities` | `critical` | Severities to pull detail for. Only critical shown on the summary page. |
| `detail_limit` | `500` | Caps detail rows fetched (`100`–`5000`). Never caps counts. |

## Where the results appear

1. **Run summary page** — totals, severity tables, critical alert table
2. **Job log** — same data as JSON
3. **Artifact** — `alert-summary.json` (30 days), every fetched severity

Summary page shows critical only (up to 50 rows); artifact has everything fetched, unabridged.

## Reading the output

| Metric | Value |
|---|---|
| **Alerts in this collection** | **491** |
| Tenant-wide (same window) | 8881 |
| Share of tenant | 5.5% |
| Cloud accounts in scope | 1 |

With `include_detail` on, a critical alert table follows (policy names truncated on the page; full in the artifact).

### Counts and detail are separate numbers

- `total` — server's count, never affected by `detail_limit`.
- `fetched` — how many detail rows came back.

A capped fetch never shrinks `total`. The page distinguishes a deliberate cap from the API stopping early (rate limiting) — only the latter warrants a re-run.

## When the run fails on purpose

Exits 1 rather than printing a misleading number:

| Status | Meaning |
|---|---|
| `collection_not_found` | No collection with that name. |
| `ambiguous_collection_name` | Two or more collections share the name. |
| `repository_only` | Collection selects only code repositories — no CSPM alerts. |
| `tenant_wide` | Collection selects all accounts. |

Count is reported as `null` in each case, never the tenant-wide total.

The alerts API silently ignores unrecognized filter names and returns HTTP 200 with the full result set (measured: `collection=foo` returned the same 8817 rows as no filter). A wrong name fails the run rather than returning that. A **"count may be unfiltered"** warning fires when the scoped total equals the tenant total.

## How a collection becomes an alert filter

```
collection name -> collection id -> asset_groups.account_ids -> one filter per account
```

**Scope actually queried** on the run summary shows the translation.

## Setup requirements

| Secret | Notes |
|---|---|
| `PRISMACLOUD_API_URL` | Tenant API host |
| `PRISMACLOUD_USERNAME` | Access key UUID |
| `PRISMACLOUD_PASSWORD` | Secret key |

No Environment or reviewer needed.

## When a run fails

| What you see | Meaning |
|---|---|
| "no counts produced" with a status | Collection resolved to something unusable (see table above). |
| "run failed" with a quoted Terraform error | Usually an input out of range. |
| "failed before or outside the Terraform plan" | Checkout, setup, or `init` failed. |

15-minute job timeout; slowest real run was ~14s.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Workflow missing from the sidebar | `workflow_dispatch` workflows only appear once on the **default branch**. |
| `collection_not_found` | Name must match the console exactly, including case and spaces. |
| Count is 0 but you expected alerts | Check **Scope actually queried** — accounts may genuinely have none. |
| "Count may be unfiltered" warning | Scoped total equals tenant total. |
| No critical table on the summary page | `include_detail` was off, or genuinely no critical alerts. |
| "credentials were incomplete, so nothing was fetched" | Detail requested but a secret is missing. |
| Want high/medium detail on the page | Artifact-only by design. Widen `detail_severities`. |
| Detail was capped | Raise `detail_limit`. |
| "Detail is incomplete and this was NOT the cap" | Pagination stopped early, usually rate limiting. Re-run. |

## More detail

Module internals, verified API findings, and every guard: [`terraform/modules/alert-summary/README.md`](../../../terraform/modules/alert-summary/README.md)

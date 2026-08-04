# Workflow 6 — Alert Summary (read-only)

**Workflow file:** [`../alert-summary.yml`](../alert-summary.yml) · **Actions name:** `6. Alert Summary (read-only)`

Answers "how many alerts does this collection have?" — a total, a severity
breakdown, the share of the tenant, and optionally the individual critical
alerts with their policy and resource names.

**Can it change the tenant?** No — and it structurally cannot.

---

## Why "cannot" rather than "does not"

Terraform can only change things declared as a `resource`. The
[`alert-summary`](../../../terraform/modules/alert-summary/README.md) module
contains **only `data` blocks — zero `resource` blocks**:

```bash
$ grep -rc "^resource" terraform/modules/alert-summary/*.tf
0        # ← nothing to create, update or delete
```

This still holds with the detail fetch enabled: it runs through
`data "external"`, which is a *data* source, and the script it calls only issues
`GET` requests.

No apply job, no approval gate. Run it as often as you like.

---

## How to use it

1. **Actions** → **6. Alert Summary (read-only)** → **Run workflow**
2. Type the **collection_name** exactly as it appears in the console
3. Optionally change status and window
4. **Run workflow**

| Input | Default | Notes |
|---|---|---|
| `collection_name` | *(required)* | Must match exactly. A wrong name fails the run rather than guessing. |
| `alert_status` | `open` | `open` \| `resolved` \| `dismissed` \| `snoozed` |
| `time_amount` | `30` | Window size |
| `time_unit` | `day` | `hour` \| `day` \| `week` \| `month` \| `year` |
| `include_detail` | `true` | Also list the individual alerts. Adds one paged API call. |
| `detail_severities` | `critical` | Which severities to pull detail for. **Only critical is shown on the summary page** — see below. |
| `detail_limit` | `500` | Caps how many detail rows are fetched. Never caps the counts. |

## Where the results appear

1. **Run summary page** — totals, severity tables, and the **critical** alert table
2. **Job log** — the same data as JSON
3. **Artifact** — `alert-summary.json` (30 days), containing **every** fetched severity

### Why critical only on the summary page

This page exists to answer "how bad is it?" at a glance. A collection here can
carry 2,000+ alerts; rendering all of them would bury the counts that are the
point of the page. So:

- **Summary page** — critical alerts, up to 50 rows
- **Artifact** — everything fetched, at full length, no truncation of policy names

If you widen `detail_severities` to `critical,high`, the high alerts are fetched
and land in the artifact; the page still shows only critical, and says so
explicitly ("Also fetched (in the JSON artifact only): high: 108").

## Reading the output

Example from a real run:

| Metric | Value |
|---|---|
| **Alerts in this collection** | **491** |
| Tenant-wide (same window) | 8881 |
| Share of tenant | 5.5% |
| Cloud accounts in scope | 1 |

The tenant-wide figure is shown deliberately. It gives the count proportion, and
it is the number the scoped total would equal if the filter had silently failed
(see below).

With `include_detail` on, a critical alert table follows:

| Policy | Resource | Type | Account | Region |
|---|---|---|---|---|
| Credential exposure risk due to a publicly exposed and vulnerable E... | ranti-splunk-instance | INSTANCE | PCS-Onboarding | us-west-1 |

Policy names are truncated to keep the table readable; the artifact has them in
full.

### Counts and detail are separate numbers

Worth understanding, because they can legitimately differ:

- **`total`** is the *server's* count. It is never affected by `detail_limit`.
- **`fetched`** is how many detail rows came back.

If the cap truncates, the page says so and still reports the true
`total_matching`. A capped fetch can never make the collection look smaller than
it is — verified: with `detail_limit=25` against 104 criticals, the run reported
`fetched: 25`, `total_matching: 104`, and the collection total stayed at 415.

The page also distinguishes **why** a list is short. A deliberate cap reads
differently from the API stopping early on us — the latter says explicitly that
the shortfall was *not* the cap, because that one warrants a re-run.

## When the run fails on purpose

The job **exits 1** rather than printing a misleading number:

| Status | Meaning |
|---|---|
| `collection_not_found` | No collection with that name. Check the spelling. |
| `ambiguous_collection_name` | Two or more collections share the name. |
| `repository_only` | The collection selects only code repositories, which CSPM alerts aren't raised against. |
| `tenant_wide` | The collection selects **all** accounts, so any count would be tenant-wide rather than team-scoped. |

In each case the count is reported as **null**, never as the tenant-wide total.

## Why a wrong name fails instead of returning something

The alerts API **silently ignores filter names it doesn't recognise** and still
returns HTTP 200 with the full result set. Measured on this tenant:

| Query | Rows |
|---|---|
| *baseline* | 8818 |
| `collection=foo` | **8817** |
| `totallyBogusParam=xyz` | **8817** |

So the naive implementation — pass the collection name as a filter — returns
every alert in the tenant and looks entirely plausible. Everything strict about
this workflow follows from that.

There is also a **"count may be unfiltered"** warning when the scoped total
exactly equals the tenant total. That can be legitimate if the collection covers
every account with alerts, so it warns rather than fails.

## How a collection becomes an alert filter

A collection can't be passed to the alerts API, so it's resolved to its cloud
accounts:

```
collection name -> collection id -> asset_groups.account_ids -> one filter per account
```

The **Scope actually queried** section on the run summary shows that
translation, so an unexpected count can be traced to the accounts that produced
it.

## Setup requirements

| Secret | Notes |
|---|---|
| `PRISMACLOUD_API_URL` | Tenant API host |
| `PRISMACLOUD_USERNAME` | Access key UUID |
| `PRISMACLOUD_PASSWORD` | Secret key |

No Environment or reviewer needed — there's nothing to gate.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Workflow missing from the sidebar | `workflow_dispatch` workflows only appear once they exist on the **default branch**. |
| `collection_not_found` | The name must match the console exactly, including case and spaces. |
| Count is 0 but you expected alerts | Check **Scope actually queried**. The collection may point at accounts that genuinely have none — that's how `collection-devsecops` behaves here. |
| "Count may be unfiltered" warning | The scoped total equals the tenant total. Verify the collection isn't effectively tenant-wide. |
| No critical table on the summary page | Either `include_detail` was off, or the collection genuinely has no critical alerts — the page distinguishes these ("None in scope" vs. no section at all). |
| "credentials were incomplete, so nothing was fetched" | Detail was requested but a secret is missing. This is **not** the same as having no alerts, which is why it is called out rather than shown as an empty table. |
| Want high/medium detail on the page | Artifact-only by design. Widen `detail_severities` and open `alert-summary.json`. |
| Detail was capped | Raise `detail_limit`. The counts were never capped — only the row list was. |
| "Detail is incomplete and this was NOT the cap" | Pagination stopped early (`empty_page` / `no_token`), usually rate limiting. Counts are still correct; re-run to get the full row list. |

## More detail

Module internals, the verified API findings, and every guard:
[`terraform/modules/alert-summary/README.md`](../../../terraform/modules/alert-summary/README.md)

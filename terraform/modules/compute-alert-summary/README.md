# compute-alert-summary

Counts the runtime incidents and image vulnerabilities inside one **Compute
collection**.

This is the sibling of [`alert-summary`](../alert-summary), not a replacement
for it. That module counts **CSPM alerts** in a **CSPM Collection**. This one
counts **Compute findings** in a **Compute collection**. The two report
different objects from different systems, and **their numbers must never be
added together**.

Read-only: the module contains only `data` blocks, so it cannot change the
tenant. A plan produces zero resource changes (verified).

## Why this module exists

`alert-summary` resolves a CSPM Collection to the cloud accounts it selects, and
then filters alerts by those accounts. That hop is the whole mechanism, and it
breaks in two ways that matter:

- A tenant that has onboarded **no cloud accounts** has nothing to filter by, so
  the CSPM path returns nothing useful no matter how the collection is defined.
- The `"<name> - Access Group (RBAC)"` collections that a Resource List spawns
  are **Compute** objects. They do not exist on the CSPM side at all — verified:
  0 of 46 CSPM collections in the reference tenant.

So "scope this by the collection the RBAC module created" is not a missing
parameter on the existing module. It is a different system, reached through a
different API, and it gets its own module.

Background and measurements:
[`plans/compute-collection-scoping-findings.md`](../../../plans/compute-collection-scoping-findings.md).

## The two collection systems

| | CSPM Collection | Compute collection |
|---|---|---|
| Endpoint | `/entitlement/api/v1/collection` | `/api/v1/collections` |
| Count (reference tenant) | 46 | 2,186 |
| Identifier | `id` field | **no id — the `name` IS the identifier** |
| Selects | account groups, accounts, repositories | accounts, namespaces, clusters, images, hosts, labels, containers, appIDs, functions |
| Used by | [`alert-summary`](../alert-summary) | **this module** |

A name shown in one console will usually not resolve in the other.

## Requirements

| Name | Version |
|---|---|
| terraform | ~> 1.13 |
| external | ~> 2.3 |

Also needs `bash`, `curl` and `jq` on the machine running Terraform. All three
are present on `ubuntu-latest`.

## Usage

```hcl
module "compute_alert_summary" {
  source = "./modules/compute-alert-summary"

  enabled         = true
  collection_name = "team-alpha-resource-list - Access Group (RBAC)"

  console_url = var.prisma_compute_console_url
  access_key  = var.prisma_cloud_access_key
  secret_key  = var.prisma_cloud_secret_key
}
```

`collection_name` must match the Compute console **exactly**. The filter is
case-sensitive; see [Guards](#guards).

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `false` | Off by default, so the module costs nothing in workflows that don't need it. |
| `collection_name` | string | `null` | Compute collection name. Required when `enabled`. Exact-match, case-sensitive. |
| `max_images` | number | `1000` | Cap on images fetched for the CVE rollup. Does **not** affect the incident or image counts. |
| `console_url` | string | `null` | Compute Console URL **including any path segment**. Required when `enabled`. |
| `access_key` | string (sensitive) | `null` | Prisma Cloud access key id. |
| `secret_key` | string (sensitive) | `null` | Prisma Cloud secret key. |
| `skip_cert_check` | bool | `false` | Self-hosted consoles with a private CA only. Never against SaaS. |

## Outputs

| Name | Description |
|---|---|
| `status` | `ok` \| `disabled` \| `missing_credentials` \| `tenant_wide_scope` \| `partial_image_scan`. **Branch on this.** |
| `status_detail` | Human-readable explanation. Null when `ok`. |
| `summary` | Every count, plus the tenant-wide totals that produced them. |
| `incidents` / `incidents_unacked` | Runtime incident counts within scope. |
| `images` | Image count within scope. |
| `vulnerabilities` | `{critical, high, medium, low}` CVE **instance** counts. |
| `scope` | What was actually queried, for troubleshooting. |

### Null means "not asked", zero means "none found"

Every count output is `null` when the module is disabled or credentials are
missing, and only ever `0` when the API was genuinely queried and returned
nothing. Collapsing those two would let a misconfigured run read as a clean
bill of health.

### Callers must branch on `status`, not the exit code

The `check` blocks emit warnings, and **a failing check does not fail the
plan**. Worse, `terraform show -json` omits the `checks` array entirely for a
plan file, so a caller cannot even detect the warning programmatically — it
appears only in human-readable stderr. Both behaviours verified against the
live tenant.

`status` exists so that a workflow has something machine-readable to test.

## Guards

### A wrong collection name fails the run

The module resolves the name against `/api/v1/collections` **before** querying
anything, and hard-fails if there is no exact match — with a suggestion when a
case-insensitive match exists:

```
no Compute collection named 'Pramm_compute_RBAC'
  - did you mean 'Pramm_compute_RBAC - Access Group (RBAC)'?
```

### An empty collection name is refused outright

Omitting the filter does not return "nothing" — it returns **the whole tenant**.
A run that silently reported 14,409 tenant-wide incidents as one team's number
would be worse than a failure, so the script refuses to run unscoped.

### Counts equal to the tenant totals are flagged

`suspect_unfiltered` fires when the scoped counts match the tenant-wide totals.
That is legitimate for an all-selecting collection (2,056 of 2,186 collections
in the reference tenant are `accountIDs: ["*"]`), so it warns rather than fails
— but it always says so.

### Credentials never touch `argv`

The token request is piped to `curl --data @-` over stdin, and the bearer token
is written to a `0700` temp file passed as `-H @file`. Nothing sensitive appears
in the process table. Verified: 0 of 25 `argv` samples during a live run
contained the secret.

## Notes & caveats

### CVE counts are instances, not images

One image with three critical CVEs contributes **three** to `critical`. These
are severity totals across the images fetched, not a count of affected images.

### The vulnerability rollup can be a sample

`images_complete` is `false` when the scan stopped at `max_images`. The incident
and image counts are server-side totals and are never affected — only the
severity rollup is. `status` reports `partial_image_scan` and the workflow
renders a prominent warning.

### Why `/images` and not `/stats/vulnerabilities`

The stats endpoint looks like exactly the right API and is **not usable**:

- **Stale.** It served a document stamped `_id: 2026-07-13` on 2026-08-11.
- **Wrong when scoped.** For a collection with 38 genuine critical CVEs it
  returned **all zeros**, while the unfiltered call returned 166.

A summary endpoint that returns zeros for a collection with real findings is
worse than no endpoint. The module pages `/images` instead and sums per page.

### Volume, and why paging is reduced in-flight

`/images` caps `limit` at 100 — `limit=500` returns HTTP 400 with no partial
data. A page of 100 is roughly **48 MB** on the wire. Each page is reduced with
`jq` before the next is fetched, taking a measured 47,965,863 bytes down to
14,260. The `fields=` query parameter is not supported here; it returns
`{"err":"unknown filtering field _id"}`.

### The filter parameter is plural

`?collections=<name>` works and **fails closed** — a nonexistent name returns 0
rather than everything, the opposite of the CSPM behaviour. The singular
`?collection=` is **silently ignored** and returns the full tenant. The script
uses the plural form and validates the name first.

### Incidents have no severity field

Compute runtime incidents carry `category`, not `severity`, so there is no
severity breakdown for incidents — only for image CVEs.

## Verified against the live tenant

Reference collection `Pramm_compute_RBAC - Access Group (RBAC)`:

| Metric | Value |
|---|---|
| Incidents in scope | 36 (of 14,409 tenant-wide) |
| Unacknowledged | 32 |
| Images in scope | 48 (of 381 tenant-wide) |
| Critical / High / Medium / Low | 38 / 662 / 585 / 93 |

Also confirmed: `terraform plan` reports **0 resource changes**; a nonexistent
collection fails the plan; a case-typo fails with a suggestion; an all-selecting
collection reports `tenant_wide_scope`.

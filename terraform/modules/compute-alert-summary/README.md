# compute-alert-summary

Counts runtime incidents and image vulnerabilities inside one **Compute collection**.

Sibling of [`alert-summary`](../alert-summary), not a replacement — that module counts CSPM alerts in a CSPM Collection; this counts Compute findings in a Compute collection. Numbers must never be added together.

Read-only: `data` blocks only. Plan produces zero resource changes (verified).

## Why this module exists

`alert-summary` resolves a CSPM Collection to cloud accounts and filters alerts by those. Breaks when: a tenant has no cloud accounts onboarded, or the collection is an RBAC-spawned `"<name> - Access Group (RBAC)"` object that only exists on the Compute side (0 of 46 CSPM collections in the reference tenant). Different system, different API, own module.

Background: [`plans/compute-collection-scoping-findings.md`](../../../plans/compute-collection-scoping-findings.md).

## The two collection systems

| | CSPM Collection | Compute collection |
|---|---|---|
| Endpoint | `/entitlement/api/v1/collection` | `/api/v1/collections` |
| Count (reference tenant) | 46 | 2,186 |
| Identifier | `id` field | no id — the `name` is the identifier |
| Selects | account groups, accounts, repositories | accounts, namespaces, clusters, images, hosts, labels, containers, appIDs, functions |
| Used by | [`alert-summary`](../alert-summary) | this module |

## Requirements

| Name | Version |
|---|---|
| terraform | ~> 1.13 |
| external | ~> 2.3 |

`bash`, `curl`, `jq` required (present on `ubuntu-latest`).

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

`collection_name` must match the Compute console exactly, case-sensitive.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `false` | Read compute counts. |
| `collection_name` | string | `null` | Compute collection name. Required when `enabled`. Exact-match, case-sensitive. |
| `max_images` | number | `1000` | Cap on images fetched for the CVE rollup. Doesn't affect incident/image counts. |
| `console_url` | string | `null` | Compute Console URL including any path segment. Required when `enabled`. |
| `access_key` | string (sensitive) | `null` | Prisma Cloud access key id. |
| `secret_key` | string (sensitive) | `null` | Prisma Cloud secret key. |
| `skip_cert_check` | bool | `false` | Self-hosted consoles with a private CA only. |

## Outputs

| Name | Description |
|---|---|
| `status` | `ok` \| `disabled` \| `missing_credentials` \| `tenant_wide_scope` \| `partial_image_scan`. Branch on this. |
| `status_detail` | Human-readable explanation. Null when `ok`. |
| `summary` | Every count plus the tenant-wide totals. |
| `incidents` / `incidents_unacked` | Runtime incident counts within scope. |
| `images` | Image count within scope. |
| `vulnerabilities` | `{critical, high, medium, low}` CVE instance counts. |
| `scope` | What was actually queried. |

`null` = not asked (disabled/missing credentials); `0` = queried, none found.

### Callers must branch on `status`, not the exit code

`check` blocks warn but don't fail the plan, and `terraform show -json` omits the `checks` array entirely.

## Guards

- **Wrong collection name fails the run.** Resolved against `/api/v1/collections` before querying; hard-fails on no exact match, with a case-insensitive suggestion:
  ```
  no Compute collection named 'Pramm_compute_RBAC'
    - did you mean 'Pramm_compute_RBAC - Access Group (RBAC)'?
  ```
- **Empty collection name is refused.** An absent filter returns the whole tenant, not nothing.
- **`suspect_unfiltered` flags counts equal to tenant totals** — legitimate for an all-selecting collection (2,056 of 2,186 in the reference tenant are `accountIDs: ["*"]`), warns rather than fails.
- **Credentials never touch `argv`** — token request via `curl --data @-` (stdin); bearer token via `-H @file` from a `0700` temp file.

## Notes & caveats

- **CVE counts are instances, not images** — one image with three critical CVEs contributes 3.
- **Vulnerability rollup can be a sample** — `images_complete = false` when the scan stopped at `max_images`; incident/image counts unaffected. `status = partial_image_scan`.
- **`/images`, not `/stats/vulnerabilities`** — the stats endpoint was stale (`_id: 2026-07-13` served on 2026-08-11) and returned all zeros for a collection with 38 genuine criticals (unfiltered call returned 166). Module pages `/images` and sums per page instead.
- **Paging is reduced in-flight** — `/images` caps `limit` at 100 (500 → HTTP 400); a page is ~48 MB, reduced with `jq` per page (47,965,863 → 14,260 bytes). `fields=` isn't supported (`{"err":"unknown filtering field _id"}`).
- **Filter parameter is plural**: `?collections=<name>` fails closed (nonexistent name → 0). Singular `?collection=` is silently ignored and returns the full tenant. Script uses the plural form and validates the name first.
- **Incidents have no severity field** — only `category`; severity breakdown applies to image CVEs only.

## Verified against the live tenant

Reference collection `Pramm_compute_RBAC - Access Group (RBAC)`:

| Metric | Value |
|---|---|
| Incidents in scope | 36 (of 14,409 tenant-wide) |
| Unacknowledged | 32 |
| Images in scope | 48 (of 381 tenant-wide) |
| Critical / High / Medium / Low | 38 / 662 / 585 / 93 |

Also confirmed: plan reports 0 resource changes; nonexistent collection fails the plan; case-typo fails with a suggestion; all-selecting collection reports `tenant_wide_scope`.

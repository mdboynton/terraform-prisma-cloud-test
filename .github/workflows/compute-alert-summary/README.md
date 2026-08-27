# Workflow 7 — Compute Alert Summary (read-only)

**Workflow file:** [`../compute-alert-summary.yml`](../compute-alert-summary.yml) · **Actions name:** `7. Compute Alert Summary (read-only)`

Runtime incident and image vulnerability counts for a **Compute** collection — counts, CVE severity breakdown, share of tenant.

Note: workflow 6 reads CSPM alerts scoped by a CSPM Collection; this reads Compute runtime incidents/image CVEs scoped by a Compute collection. Numbers are not comparable.

## How to use it

1. **Actions** → **7. Compute Alert Summary (read-only)** → **Run workflow**
2. Type the **collection_name** exactly as it appears in the Compute console
3. Optionally change `max_images`
4. **Run workflow**

| Input | Default | Notes |
|---|---|---|
| `collection_name` | *(required)* | Must match the Compute console exactly, case-sensitive. |
| `max_images` | `1000` | Caps images fetched for the CVE rollup. Never caps incident or image counts. |

### Getting the name right

Copy it from **Compute** → **Manage** → **Collections**. Compute collections have no id — the name is the identifier.

```
no Compute collection named 'Pramm_compute_RBAC'
  - did you mean 'Pramm_compute_RBAC - Access Group (RBAC)'?
```

## Where the results appear

1. **Run summary page** — incident counts and CVE severity table
2. **Job log** — artifact size, raw plan output
3. **Artifact** — `compute-alert-summary.json` (30 days), every field

## Reading the output

```
## Compute alert summary

**Collection:** `Pramm_compute_RBAC - Access Group (RBAC)`

### Runtime incidents

| Metric | Value |
|---|---|
| **Incidents in this collection** | **36** |
| Unacknowledged | 32 |
| Tenant-wide | 14409 |
| Share of tenant | 0.2% |

### Image vulnerabilities

| Metric | Value |
|---|---|
| **Images in this collection** | **48** |
| Tenant-wide | 381 |

| Severity | CVE instances |
|---|---|
| Critical | 38 |
| High | 662 |
| Medium | 585 |
| Low | 93 |
```

- CVE table counts findings, not images — one image with three critical CVEs contributes 3.
- Incidents have no severity, only a category and an unacknowledged count.
- The two sections are independent — never add them.

## When the page warns you

- **"Vulnerability totals are incomplete"** — CVE rollup stopped at `max_images`; a sample. Incident/image counts are server-side totals, unaffected.
- **"This collection's counts equal the tenant-wide totals"** — legitimate for an all-selecting collection, but also what a dropped filter looks like. Check the collection's scope.

Neither warning fails the run.

## When the run fails on purpose

| The run fails when | Because |
|---|---|
| Collection name has no exact match | Guessing would attribute the wrong team's findings. |
| Collection name is empty | An absent filter returns the whole tenant, not nothing. |
| Module disabled or credentials missing | Rendering zeros would read as "no findings". |

Summary page says "No counts were produced" rather than showing a number.

## Setup requirements

| Secret | Used for |
|---|---|
| `PRISMA_COMPUTE_CONSOLE_URL` | Compute Console, including the path segment |
| `PRISMACLOUD_USERNAME` | Access key id |
| `PRISMACLOUD_PASSWORD` | Secret key |

Stripping the path segment authenticates "successfully" but returns an empty token — looks like a credentials problem.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `no Compute collection named ...` | Copy the name verbatim; check trailing spaces. |
| `did you mean ...` | Use the suggested name — case mismatch. |
| `authentication returned no token` | `PRISMA_COMPUTE_CONSOLE_URL` missing its path segment. |
| Counts look far too high | Check for the tenant-wide warning. |
| Severity numbers lower than expected | Check for the incomplete-scan warning; raise `max_images`. |
| Timed out | Lower `max_images`, or re-run if rate limited. |
| Looking for CSPM alerts? | Wrong workflow — use [workflow 6](../alert-summary/README.md). |

## More detail

- This workflow's bash is self-contained in [`../compute-alert-summary.yml`](../compute-alert-summary.yml) — no Terraform, no checkout. `terraform/modules/compute-alert-summary/scripts/summary.sh` implements the same logic for the Terraform module and is not called by this workflow.
- Why Compute collections are a separate system from CSPM Collections: [`plans/compute-collection-scoping-findings.md`](../../../plans/compute-collection-scoping-findings.md)

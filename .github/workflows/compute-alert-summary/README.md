# Workflow 7 — Compute Alert Summary (read-only)

**Workflow file:** [`../compute-alert-summary.yml`](../compute-alert-summary.yml) · **Actions name:** `7. Compute Alert Summary (read-only)`

Answers "how many runtime incidents and image vulnerabilities does this
**Compute** collection have?" — the counts, a CVE severity breakdown, and the
share of the tenant.

**Can it change the tenant?** No — and it structurally cannot.

---

## This is not workflow 6

Prisma has **two unrelated collection systems**, and this pair of workflows
reads one each:

| | Workflow 6 — Alert Summary | Workflow 7 — this one |
|---|---|---|
| Reads | CSPM **alerts** | Compute **runtime incidents** + **image CVEs** |
| Scoped by | a **CSPM** Collection | a **Compute** collection |
| How the scope is applied | collection → cloud accounts → alert filter | collection name → Compute API filter |

**The numbers are not comparable and must never be added together.** They count
different objects from different systems.

### Which one do I want?

- The collection appears in **Compute** → **Manage** → **Collections**, or its
  name ends in **`- Access Group (RBAC)`** → **workflow 7**.
- The collection appears under **Settings** → **Collections** in the main
  console, and you want posture/config alerts → **workflow 6**.
- Your tenant has **no cloud accounts onboarded** → workflow 6 has nothing to
  scope by. Use **workflow 7**.

A name from one console will usually not resolve in the other, and both
workflows fail rather than guess.

---

## Why "cannot" rather than "does not"

Terraform can only change things declared as a `resource`. The
[`compute-alert-summary`](../../../terraform/modules/compute-alert-summary/README.md)
module contains **only `data` blocks — zero `resource` blocks**:

```bash
$ grep -rc "^resource" terraform/modules/compute-alert-summary/*.tf
0        # ← nothing to create, update or delete
```

The counts come through `data "external"`, which is a *data* source, and the
script it calls only issues `GET` requests (plus the `POST` that authenticates).
A live plan was confirmed to report **0 resource changes**.

No apply job, no approval gate. Run it as often as you like.

---

## How to use it

1. **Actions** → **7. Compute Alert Summary (read-only)** → **Run workflow**
2. Type the **collection_name** exactly as it appears in the Compute console
3. Optionally change `max_images`
4. **Run workflow**

| Input | Default | Notes |
|---|---|---|
| `collection_name` | *(required)* | Must match the Compute console **exactly**. The filter is case-sensitive. A wrong name fails the run rather than guessing. |
| `max_images` | `1000` | Caps how many images are fetched for the CVE rollup. **Never caps the incident or image counts.** |

### Getting the name right

Copy it from **Compute** → **Manage** → **Collections**. Compute collections
have no id — the name *is* the identifier — so a stray space or a lowercase
letter is the difference between a match and a failure.

If you get the case wrong, the error tells you the right one:

```
no Compute collection named 'Pramm_compute_RBAC'
  - did you mean 'Pramm_compute_RBAC - Access Group (RBAC)'?
```

## Where the results appear

1. **Run summary page** — incident counts and the CVE severity table
2. **Job log** — the artifact size, and the raw plan output
3. **Artifact** — `compute-alert-summary.json` (30 days), containing every
   field including the ones not rendered on the page

## Reading the output

Example from a real run:

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

### CVE instances, not affected images

One image carrying three critical CVEs contributes **three** to the critical
row. The severity table counts findings, not images. "48 images, 38 critical"
does not mean 38 of the 48 images are bad.

### Incidents have no severity

Compute runtime incidents carry a *category*, not a severity, so there is no
severity split for them — only the unacknowledged count.

### The two sections are independent numbers

Runtime incidents and image vulnerabilities come from different endpoints and
describe different things. Do not add them.

---

## When the page warns you

### "Vulnerability totals are incomplete"

The CVE rollup stopped at `max_images`, so the severity numbers are a
**sample**. Re-run with a higher `max_images` for complete figures. The
incident and image counts are server-side totals and are unaffected.

### "This collection's counts equal the tenant-wide totals"

The scoped counts came back identical to the whole tenant. That is legitimate
for an all-selecting collection — most collections in a typical tenant select
everything (`accountIDs: ["*"]`) — but it is also exactly what a dropped filter
would look like, so the run always says so. Check the collection's scope before
reporting these as one team's numbers.

Neither warning fails the run.

---

## When the run fails on purpose

Some failures are the design working:

| The run fails when | Because |
|---|---|
| The collection name has no exact match | Guessing at a name would attribute the wrong team's findings to yours. |
| The collection name is empty | An absent filter returns **the whole tenant**, not nothing. Reporting 14,409 tenant-wide incidents as one team's count is worse than failing. |
| The module is disabled or credentials are missing | No counts were produced. Rendering zeros would read as "no findings", which is a lie. |

In every case the summary page says **"No counts were produced"** rather than
showing a number.

## Setup requirements

Repository secrets:

| Secret | Used for |
|---|---|
| `PRISMA_COMPUTE_CONSOLE_URL` | The Compute Console, **including the path segment** (e.g. `https://<region>.cloud.twistlock.com/us-2-158320372`) |
| `PRISMACLOUD_USERNAME` | Access key id |
| `PRISMACLOUD_PASSWORD` | Secret key |
| `PRISMACLOUD_API_URL` | The CSPM provider is configured at the root, so it needs a URL even though this workflow never calls it |

Stripping the path segment off the console URL authenticates
"successfully" and returns an **empty token**, so the failure looks like a
credentials problem rather than a URL problem. Include the full path.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `no Compute collection named ...` | Copy the name from the Compute console verbatim. Check for trailing spaces. |
| `did you mean ...` | Use the suggested name — you have a case mismatch. |
| `authentication returned no token` | `PRISMA_COMPUTE_CONSOLE_URL` is missing its path segment. |
| Counts look far too high | Check for the tenant-wide warning; the collection may select everything. |
| Severity numbers lower than expected | Check for the incomplete-scan warning; raise `max_images`. |
| Timed out | Lower `max_images`, or re-run if the tenant is rate limiting. |
| Looking for CSPM alerts? | Wrong workflow — use [workflow 6](../alert-summary/README.md). |

## More detail

- Module reference: [`terraform/modules/compute-alert-summary/README.md`](../../../terraform/modules/compute-alert-summary/README.md)
- Why this is a separate module: [`plans/compute-collection-scoping-findings.md`](../../../plans/compute-collection-scoping-findings.md)

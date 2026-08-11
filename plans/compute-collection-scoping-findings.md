# Verification: scoping a summary by a COMPUTE collection (workflow 5 gap)

Raised by a colleague reviewing workflow 5 (`alert-summary`, read-only):

> "I noticed that it's keying off of the cloud account IDs. that would be fine
> for probably any other prisma customer, but these guys aren't onboarding cloud
> accounts at all. ideally, if this could be updated so that it accepts a Compute
> Access Group collection (which is spawned when you make a resource list) and
> summarizes alerts based on the workloads within the scope of that collection,
> that would be a much better solution"

He is right. This document records what was verified against the live tenant,
and why the fix is a sibling module rather than a new input.

All figures below were measured, not assumed. They come from one tenant and are
a mix of **product behaviour** (portable) and **tenant contents** (not
portable); each section says which.

---

## 0. First, the thing that was NOT wrong

Workflow 5 does **not** treat a collection id as a cloud account id. It
translates one into the other:

```
collection name -> collection id -> asset_groups -> account_ids -> cloud.accountId
```

See [`main.tf`](../terraform/modules/alert-summary/main.tf) —
`raw_account_ids = distinct(flatten([for g in local.asset_groups : g.account_ids]))`.

The translation exists because the CSPM alerts API has **no collection filter**,
and an unrecognised filter name is silently ignored and returns the full
tenant-wide set (see
[`alerts-by-collection-findings.md`](alerts-by-collection-findings.md) §1). The
account-id hop was the safe way to honour a collection-shaped request.

So the design is sound. It is just solving the problem for the wrong *kind* of
collection for this customer.

---

## 1. There are TWO separate collection systems

This is the root of the issue, and it was previously blurred by calling both
"collections".

| | CSPM collection | Compute collection |
|---|---|---|
| endpoint | `GET /entitlement/api/v1/collection` | `GET /api/v1/collections` |
| count in this tenant | 46 | **2,186** |
| selector vocabulary | `accountGroupIds`, `accountIds`, `repositoryIds` | `accountIDs`, `namespaces`, `clusters`, `images`, `hosts`, `labels`, `containers`, `appIDs`, `functions` |
| `"... - Access Group (RBAC)"` objects | **0** | yes, many |

Selector usage across the 46 CSPM collections (tenant contents):

| Selector | Collections using it |
|---|---|
| `accountGroupIds` | 35 |
| `accountIds` | 24 |
| `repositoryIds` | 18 |

**The Compute Access Group collection that a Resource List spawns does not exist
on the CSPM side at all.** Workflow 5 reads `prismacloud_collections`, which is
the CSPM list, so it cannot see those objects. Passing one of their names to the
workflow today produces `collection_not_found` — the guard fires correctly, but
the answer the colleague wants is simply not reachable from that data source.

---

## 2. Why the account-id hop cannot rescue this

Even if the Compute collections were visible, the translation would not work.

**2,056 of 2,186** Compute collections have `accountIDs: ["*"]` (tenant
contents, but structurally expected — an Access Group scopes workloads, not
accounts). Those collections express their real scope through `namespaces` and
`clusters`:

```json
{ "name": "Sock-shop - Access Group (RBAC)",
  "accountIDs": ["*"], "clusters": ["gke-hs-cluster-1"], "namespaces": ["sock-shop"] }

{ "name": "Pramm_compute_RBAC - Access Group (RBAC)",
  "accountIDs": ["*"], "clusters": ["*"], "namespaces": ["*kube*"] }
```

`accountIDs: ["*"]` hits the existing wildcard guard (GUARD 2) and yields **no
scope** — correctly refusing to report a tenant-wide number as if it were
team-scoped, but useless as an answer.

For a customer that onboards no cloud accounts, the account-id path has nothing
to work with by construction. This is not a tuning problem.

---

## 3. The Compute API DOES have a collection filter

This is the finding that makes the request straightforwardly buildable, and it
is the **opposite** of the CSPM behaviour that shaped workflow 5.

Measured with the `Total-Count` response header (product behaviour):

| Query | Total-Count |
|---|---|
| `GET /api/v1/audits/incidents` | 14,409 |
| `...?collections=<a real collection>` | 13,596 |
| `...?collections=NO-SUCH-COLLECTION-XYZ` | **0** |

The filter applies, and **it fails closed** — a name that matches nothing
returns 0, not everything. No silent-drop trap on this endpoint.

Verified against genuinely narrow collections:

| Collection | Scope | Incidents |
|---|---|---|
| `Pramm_compute_RBAC - Access Group (RBAC)` | namespaces `*kube*` | **36** |
| `Sock-shop - Access Group (RBAC)` | ns `sock-shop`, cluster `gke-hs-cluster-1` | 0 |
| `tadenugba RLN - Access Group (RBAC)` | ns `tadenugba Namespace` | 0 |

It works on vulnerability data too: `GET /api/v1/images?collections=...`
(unfiltered 396, fake collection 0).

So "summarise findings for the workloads in this Compute collection" is a
**supported, first-class query** — against Compute, not CSPM.

### ⚠️ TRAP: the parameter is PLURAL

```
?collections=NO-SUCH-XYZ   -> 0        (filter applied)
?collection=NO-SUCH-XYZ    -> 14,409   (silently ignored)
```

The singular form is dropped and returns the full unfiltered set. Same failure
mode as the CSPM alerts API, different endpoint. **Any implementation must
assert that the filtered count differs from the unfiltered baseline** rather
than trusting a plausible-looking number — the same discipline
[`alert-summary`](../terraform/modules/alert-summary/README.md) already applies.

---

## 4. Consequence for the design: a sibling module, not a new input

The colleague's ask is sound, but it is **a second data source, not a
parameter**:

| | workflow 5 (`alert-summary`) | proposed `compute-alert-summary` |
|---|---|---|
| API | CSPM `/v2/alert` | Compute `/api/v1/audits/incidents`, `/api/v1/images` |
| auth | CSPM `x-redlock-auth` | Compute `Authorization: Bearer` (different host) |
| scoping | resolve collection -> accounts | `?collections=<name>` direct |
| counts | CSPM alerts | runtime incidents / image vulns |

These cannot merge cleanly. Different hosts, different auth, different scoping
semantics — and critically, **the numbers are not comparable**, so folding them
into one output invites the reader to add or compare two unrelated totals.

Recommended shape: a sibling module following the
[`compute-runtime-policies`](../terraform/modules/compute-runtime-policies)
script pattern (the Compute provider has no data source for this), with the same
guard discipline as `alert-summary`:

- explicit `status` output; callers branch on it, never on exit code
- assert filtered != unfiltered baseline (the plural-parameter trap)
- distinguish "no findings" from "we fetched nothing"
- page it — `Total-Count` is 14,409 and `/api/v1/images` **caps `limit` at 100**
  (`limit=500` returns HTTP 400 `{"err":"limit must be at most 100"}` with no
  partial data)

### Expectation-setting for the customer

This reports **Compute** findings — runtime incidents and image vulnerabilities.
If they also want CSPM config/IAM/network alerts, those genuinely cannot be
scoped this way: with no cloud accounts onboarded there are no CSPM alerts to
scope. Worth saying plainly rather than letting "alerts" imply both.

---

## Summary

| Question | Answer |
|---|---|
| Did workflow 5 equate collection id with account id? | **No** — it resolves one to the other, deliberately |
| Is the colleague's criticism valid? | **Yes** — the account hop is unusable without onboarded accounts |
| Are CSPM and Compute collections the same objects? | **No** — separate systems, 46 vs 2,186, disjoint selectors |
| Can a Compute Access Group collection be seen by workflow 5? | **No** — 0 exist on the CSPM side |
| Can Compute findings be scoped by collection? | **Yes** — `?collections=` works and fails closed |
| Fix as a new input to workflow 5? | **No** — different API/auth/semantics; build a sibling module |
| Biggest trap | `collection=` (singular) is silently ignored; use `collections=` |

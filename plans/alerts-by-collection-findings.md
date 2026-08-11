# Verification: "alerts for a collection" (CSPM)

All figures below came from the live tenant (`api2.prismacloud.io`) and the
provider schema, not from documentation or recall. Dated 2026-07-31.

---

## 1. There is no collection filter, and worse, asking for one fails silently

The alert API publishes 31 filter names via `GET /filter/alert/suggest`:

```
account.group        alert.id             alert.status         alertRule.name
asset.class          buildtime.resourceName                    cloud.account
cloud.accountId      cloud.region         cloud.service        cloud.type
git.filename         git.provider         git.repository       iac.framework
policy.aiRemediable  policy.complianceRequirement
policy.complianceSection                  policy.complianceStandard
policy.label         policy.name          policy.remediable    policy.severity
policy.subtype       policy.type          resource.group       resource.id
resource.name        resource.type        timeRange.type       vulnerability.severity
```

**No collection filter exists.** That alone would be a simple "no". The dangerous
part is how the API responds to one anyway:

| Query (open alerts, 30d) | Rows | Verdict |
|---|---|---|
| *(baseline)* | 8818 | — |
| `collection=foo` | 8817 | **silently ignored** |
| `collection=tuan-test-assets` | 8818 | **silently ignored** |
| `totallyBogusParam=xyz` | 8817 | **silently ignored** |
| `resource.group=NoSuchGroup` | 0 | applied |
| `alertRule.name=NoSuchRule` | 0 | applied |
| `account.group=NoSuchAccountGroup` | 0 | applied |

An **unrecognised filter name is dropped and the request returns HTTP 200**.

This is the worst possible failure mode for a reporting workflow. A naive
implementation passing `collection=<name>` would return all 8,818 tenant-wide
alerts, and the user would read that as "my team has 8,818 alerts." The output
looks completely plausible. There is no error, no warning, no empty result to
signal the mistake.

A *recognised* filter with an unknown value correctly returns 0, so the
distinction is filter NAME validity, not value validity.

### Consequence for the design

Any module must **validate filter names against the tenant's own
`/filter/alert/suggest` list before querying**, and fail loudly on an unknown
name. Trusting the HTTP status code is not sufficient here.

---

## 2. CORRECTION: the data source DOES work — use it, with a cap

> **This section originally concluded "use a script, not the data source." That
> was wrong on the main point.** I had inferred it from the volume numbers and
> the thin `listing` object without actually trying the data source. Tested, it
> filters correctly. The volume concern below is real but is a reason to *cap*
> the query, not to abandon the provider. Correction kept visible rather than
> silently rewritten.

Proven end to end, no scripts, in a scratch workspace:

```hcl
data "prismacloud_collections" "all" {}

data "prismacloud_collection" "c" {
  id = one([for c in data.prismacloud_collections.all.listing : c.id
            if c.name == "collection-devsecops"])
}

locals {
  # asset_groups is a SET, so it cannot be indexed - flatten across elements.
  acct_ids = distinct(flatten([for g in data.prismacloud_collection.c.asset_groups : g.account_ids]))
}

data "prismacloud_alerts" "by_collection" {
  limit = 1
  time_range {
    relative {
      amount = 30
      unit   = "day"
    }
  }
  filters {
    name  = "alert.status"
    value = "open"
  }
  filters {
    name  = "cloud.accountId"
    value = join(",", local.acct_ids)
  }
}
```

Results:

| Check | Result |
|---|---|
| Collection name resolves to `asset_groups` | yes — `{account_ids, account_group_ids, repository_ids}` |
| Filter actually applies | **yes** — `baseline=8863` vs `scoped=116` |
| Non-no-op resource changes in the plan | **0** (read-only, as required) |

So the whole feature is expressible in plain Terraform. That is preferable to a
script: no bash, no `jq`, no auth handling of our own, and it matches the
existing read-only module pattern.

### Two gotchas found while testing

1. **`asset_groups` is a set, not a list.** `asset_groups[0]` fails with
   *"Elements of a set are identified only by their value and don't have any
   separate index"*. Use `flatten([for g in ... : g.account_ids])`.
2. **Nested blocks need their own lines.** `time_range { relative { ... } }` on
   one line is a parse error in HCL.

---

## 2b. Volume still constrains how the data source is used

- **8,820** open alerts in the last 30 days.
- `detailed=true` averages **~20.8 KB per alert**; one 500-alert page was
  **10,425,312 bytes (10 MB)**.
- `detailed=false` is far smaller but still ~3 KB per alert.

A data source embeds its entire result in the plan JSON, and every consumer
re-reads that. Extrapolated, a detailed tenant-wide pull is on the order of
**180 MB of plan JSON**. Even at the provider's 10,000-row cap this is not
viable.

This is a genuinely different situation from the access-audit case, where I
argued volume was a non-issue (452 rows at ~60 bytes each). Here it is the
dominant constraint.

**Therefore: keep `limit` small and lean on `total`.** The data source exposes a
`total` attribute (the server-side count) independently of how many rows it
returns, so `limit = 1` yields the count for free without pulling the payload.
That is how the verified example above gets 8863 / 116.

Only aggregates and a small capped sample should ever reach Terraform outputs.

### The `listing` object is thin — plan around it

`prismacloud_alerts.listing` exposes only:

```
alert_id, alert_count, alert_time, event_occurred,
first_seen, last_seen, status, triggered_by
```

There is **no resource, policy, severity, or account field**. So the data source
is excellent for **counts and breakdowns** (query once per severity / status /
policy type and read `total`), but it cannot produce a per-alert table with
resource names.

If per-alert detail is genuinely needed, that is the one case for a
supplementary script — the same call made for
[`compute-runtime-policies`](../terraform/modules/compute-runtime-policies/README.md).
Start without it; a counts-and-breakdown report may well be enough.

Note the `filters` block is a free-form `name`/`value` list: the provider does
no validation and forwards names straight to the API, so it **inherits the
silent-drop behaviour** from §1. The baseline-comparison guard applies equally
to the data source.

---

## 3. Compute incidents DO appear in the CSPM alert stream

Confirmed, as the colleague described. `policyType` distribution across a
500-alert page of open alerts:

| policyType | Count |
|---|---|
| `config` | 432 |
| `iam` | 25 |
| `workload_vulnerability` | 23 |
| `network` | 19 |
| `workload_incident` | 1 |

`workload_incident` is a Compute/Twistlock incident promoted into a CSPM alert.

**This means one workflow against the CSPM alerts API covers both worlds.** No
second Compute code path is needed, which removes the CSPM-vs-Compute collection
split as a concern for *this* feature.

---

## 4. Scoping: what actually works

Since collections are out, alerts must be scoped the way the API supports.
Verified working:

| Filter | Example | Rows |
|---|---|---|
| `account.group` | `All AWS Accounts` | 4182 |
| `policy.severity` | `high` | 1746 |
| `policy.type` | `config` | 7028 |
| `resource.group` | *(validated: unknown value returns 0)* | — |
| `alertRule.name` | **unusable in this tenant — see below** | 0 |

### `alertRule.name` is a dead end here

My first instinct was to scope by Alert Rule, since the rbac module creates one
per team. Checked against real data, that does not work:

```
alerts carrying a non-empty `alertRules` array:   0 / 500
alerts carrying `resource.cloudAccountGroups`:  493 / 493
```

**No open alert is attributed to an alert rule.** This is consistent with what
Alert Rules actually do: they govern *notification routing*, not alert
generation. A policy evaluating a resource produces the alert; the rule decides
who gets told. So filtering alerts by rule name returns nothing, and
`alertRule.name=VA All Cloud Compute Alert Rule` returning 0 was not an encoding
problem — it was the correct answer.

Had I designed around `alertRule.name` on the strength of it appearing in the
filter list, the workflow would have shipped returning zero alerts for every
team.

### The scope that does work: Account Group

Every alert carries `resource.cloudAccountGroups`, and `account.group` is a
supported filter that behaves correctly (4182 rows for a real group, 0 for a
fake one). That is the reliable team scope.

The rbac module's Account Groups are therefore the join key, rather than its
Alert Rule. Note the constraint recorded in
[`rbac/main.tf`](../terraform/modules/rbac/main.tf) — the alert-rule *target*
cannot set both `account_groups` and `resource_list`:

```hcl
target {
  # account_groups is intentionally omitted: the API rejects a target that
  # sets both account_groups and resource_list
  resource_list {
    compute_access_group_ids = [for rl in prismacloud_resource_list.team : rl.id]
  }
}
```

So the natural input is a **team name**, resolved to that team's **Account
Group(s)** and queried via `account.group`. Same user-facing question, expressed
in terms the API can answer exactly rather than approximately.

`resource.group` (Resource List) is a plausible secondary scope but was only
validated negatively — an unknown value returns 0. Confirm it positively against
a known-good value before relying on it.

---

## 4b. Building our own "data source": collection -> filters DOES work

The follow-up question was whether a script combining API calls could filter by
collection where the alert API alone cannot. **Yes** — and it is simpler than
feared, because a CSPM collection is a thin object.

`GET /entitlement/api/v1/collection` returns 45 collections in this tenant. A
representative one:

```json
{
  "id": "ff93637a-d2db-4605-9b59-5e975be69c05",
  "name": "collection-devsecops",
  "assetGroups": {
    "accountGroupIds": ["15a8eab3-f141-461e-b3b8-b161bf6bdc97"],
    "accountIds": ["587930185011"]
  }
}
```

A collection is **only** an `assetGroups` selector. Across all 45, the complete
vocabulary is three keys:

| Selector | Collections using it | Maps to alert filter |
|---|---|---|
| `accountGroupIds` | 34 | `account.group` (after ID -> name lookup) |
| `accountIds` | 23 | `cloud.accountId` **direct** |
| `repositoryIds` | 18 | *(no equivalent — code-repo scope, not cloud alerts)* |

There are no tag, cluster, or namespace selectors to worry about. That was the
main risk in §4 and it does not materialise.

### Verified end to end

`cloud.accountId` filters correctly against an account known to have alerts:

| Query | Rows | Verdict |
|---|---|---|
| *baseline* | 8869 | — |
| `cloud.accountId=082654650179` | **139** | applied |
| `cloud.account=jjeanclaude-panopto` | **139** | applied (name form agrees) |
| `cloud.accountId=000000000000` | 0 | applied, no match |

The two forms agreeing on 139 is a useful cross-check: the filter is real, not
coincidence.

**A caution on interpreting zero.** The first six collections tested all returned
0 alerts, which initially looked like the silent-drop trap from §1. It was not —
those are test collections pointing at accounts with genuinely no alerts. The
only way to tell the two apart is to compare against the tenant-wide baseline: a
dropped filter returns **the baseline**, a working filter with no matches returns
**0**. The module must apply that check rather than trusting a plausible-looking
number.

### Design

The raw API calls are what the provider issues internally. Since provider data
sources cover all three steps (§2), the module is **plain Terraform** — no
scripts:

```
prismacloud_collections  -> find id by name
prismacloud_collection   -> asset_groups
  account_ids       -> filters { name = "cloud.accountId", value = join(",", ...) }
  account_group_ids -> resolve to names -> filters { name = "account.group", ... }
prismacloud_alerts       -> total   (limit = 1, so no payload is pulled)
```

Verified end to end with 0 resource changes.

Required guards:

1. **Fail if the collection name doesn't resolve** — do not fall back to an
   unfiltered query.
2. **Fail if a collection yields no translatable selector** (e.g. `repositoryIds`
   only) rather than silently returning tenant-wide alerts.
3. **Compare against the baseline count** to distinguish "filter ignored" from
   "genuinely zero", per the caution above.
4. `accountGroupIds` needs an ID-to-name lookup; `account.group` matches on name.

One unresolved detail: `mdalbes-collection` has `accountIds: ["*"]`. A literal
`*` must be treated as "all accounts" — i.e. omit the filter and label the result
tenant-wide — not passed through as an account ID.

---

## 5. Drift detection must not ingest this

Alerts are high-churn by nature — the count moved from 8764 to 8820 during this
investigation, roughly an hour. Feeding them into
[`snapshot.sh`](../scripts/drift/snapshot.sh) would make the baseline change on
every run and reduce drift detection to noise.

**Alerts stay out of the drift snapshot.** If alert trends are wanted later,
that is a separate time-series concern, not a drift baseline.

---

## Open questions

1. ~~Why does `alertRule.name` for a known rule return 0?~~ **Resolved** (§4):
   alerts are not attributed to alert rules at all. Rules route notifications;
   policies generate alerts. Scope by `account.group` instead.
2. Confirm `resource.group` positively against a known Resource List, so it can
   serve as a secondary scope.
3. Should the workflow accept a team name and resolve it to Account Groups, or
   take an explicit Account Group?
4. Is `detailed=false` sufficient, or is per-alert resource detail needed? This
   drives the volume budget (~3 KB vs ~20.8 KB per alert).

---

## 6. FOLLOW-UP: this covers CSPM collections only

Everything above concerns **CSPM** collections. A later review surfaced that
Prisma has a **second, unrelated** collection system in Compute, and the
"Access Group (RBAC)" collections spawned by a Resource List live only there —
**0 of the 46 CSPM collections are of that kind.**

Two consequences for anyone reusing §4b:

1. **The account hop does not generalise.** 2,056 of 2,186 Compute collections
   are `accountIDs: ["*"]` and express their real scope through `namespaces` /
   `clusters`. Resolving them to accounts yields no scope.
2. **Compute does not need the workaround.** `GET /api/v1/audits/incidents`
   accepts a real `?collections=` filter, and it **fails closed** — a bad name
   returns 0 rather than the full set. The silent-drop trap in §1 is a CSPM
   behaviour, not a universal one.

See
[`compute-collection-scoping-findings.md`](compute-collection-scoping-findings.md).

---

## Summary

> **Scope of this document: CSPM only.** Compute has a separate collection
> system that behaves differently — see §6.

| Question | Answer |
|---|---|
| Can the **CSPM** alert API filter by collection directly? | **No** — no such filter exists (Compute's *can*, see §6) |
| Can we do it ourselves by combining calls? | **Yes** — a collection is just `assetGroups`; resolve it, then filter by account (§4b) |
| Does the API reject an invalid filter? | **No** — silently ignored, returns everything (CSPM; Compute fails closed) |
| Use the `prismacloud_alerts` data source? | **Yes** — filters correctly; use `limit = 1` and read `total` |
| Do we need scripts? | **No** for counts. Only if per-alert resource detail is required |
| Do Compute incidents appear here? | **Yes** — `workload_incident`, `workload_vulnerability` |
| What scopes a team's alerts? | `cloud.accountId` / `account.group`, **not** `alertRule.name` |
| Does this work for a Compute Access Group collection? | **No** — those are Compute-only objects; see §6 |
| Include alerts in drift detection? | **No** — too high-churn |

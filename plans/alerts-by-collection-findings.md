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

## 2. Volume makes a Terraform data source the wrong tool

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

**Therefore: use a script (`curl` + `jq`), not the `prismacloud_alerts` data
source.** Same reasoning that produced
[`compute-runtime-policies`](../terraform/modules/compute-runtime-policies/README.md):
when the provider doesn't fit, a script gives pagination, an explicit cap, real
error bodies, and control over what enters the plan.

Only aggregates and a capped sample should ever reach Terraform outputs.

### Provider data source, for the record

`prismacloud_alerts` exists but is a poor fit independent of volume. Its
`listing` object exposes only:

```
alert_id, alert_count, alert_time, event_occurred,
first_seen, last_seen, status, triggered_by
```

There is **no resource, policy, severity, or account field**, so it cannot
produce a useful per-team alert report even if volume were acceptable. Its
`filters` block is a free-form `name`/`value` list, meaning the provider does
no validation either — it forwards names straight to the API, inheriting the
silent-drop behaviour above.

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

## Summary

| Question | Answer |
|---|---|
| Can we filter alerts by collection? | **No** — no such filter exists |
| Does the API reject an invalid filter? | **No** — silently ignored, returns everything |
| Use the `prismacloud_alerts` data source? | **No** — volume, and `listing` lacks the needed fields |
| Do Compute incidents appear here? | **Yes** — `workload_incident`, `workload_vulnerability` |
| What should scope a team's alerts? | **`account.group`**, not `alertRule.name` |
| Include alerts in drift detection? | **No** — too high-churn |

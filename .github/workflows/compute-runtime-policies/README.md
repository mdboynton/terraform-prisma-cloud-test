# Workflow 2 — Compute Runtime Policies

**Workflow file:** [`../compute-runtime-policies.yml`](../compute-runtime-policies.yml) · **Actions name:** `2. Compute Runtime Policies`

Two capabilities for Prisma Cloud **Compute** runtime policies (Container + Host):

- **List** (read-only) — see which rules exist and where they apply
- **Apply** (gated) — attach an RBAC collection to an **existing** rule

**Can it change the tenant?** ✅ Yes — behind an approval gate. But note what it
*can't* do: it never creates, redefines or deletes a policy. It only **appends**
a collection to a rule you already have, keeping everything already on that rule.

---

## Why this one uses scripts

The Terraform provider ships **no data source** for runtime policies, so this
module talks to the Compute Console API directly via shell scripts. That's the
exception in this repo — workflows 1 and 3 use native provider resources.

---

## Just want to look? (most common)

1. **Actions** → **2. Compute Runtime Policies** → **Run workflow**
2. Leave `apply` **unchecked**. Optionally set:
   - `list_collection` — restrict the index to one collection
   - `list_clusters` — comma-separated clusters to resolve
3. Run → open the **Plan (and list)** job → expand **"Runtime policy listing"**

### The three views you get

| Output | Answers |
|---|---|
| `*_rules_by_cluster` | "Which rules apply to **this cluster**?" |
| `*_rules_by_collection` | "Which rules reference **this collection**?" |
| Full dump (in plan output) | "What rules exist at all?" |

Cluster resolution walks **cluster → collections that specifically select it →
rules**. Collections with the `*`/`All` wildcard are deliberately excluded —
they aren't cluster-specific and would match everything.

---

## Attaching a collection to a rule

### Step 1 — Find the rule name

Run the listing first (above). `policy_rule_name` must match an existing rule
**exactly**.

### Step 2 — Declare the association

Associations live in `terraform/config/compute-runtime-policies.yaml`
(git-ignored; copy from
[`the example`](../../../terraform/config/compute-runtime-policies.example.yaml)):

```yaml
container_associations:
  - policy_rule_name: "runtime-demo"
    add_collection: "my-team-collection"

host_associations:
  - policy_rule_name: "host-runtime-demo"
    add_collection: "my-team-collection"
```

The collection must already exist in the tenant.

### Step 3 — Preview (the dry run)

There is nothing to enable — **the dry run happens automatically on every run**,
including plain pushes and PRs. Open the run → **Plan (and list)** job → the step
named **"Association dry run (what the apply would actually change)"**.

**Read this step, not the plan.** The Terraform plan can only ever say
`1 to add` / `2 to add`, because the write is performed by a script inside a
`null_resource` and Terraform cannot see through it. That number is bookkeeping,
not the policy diff. The dry run is the real preview — it queries the live policy
and reports, per association:

| Status | Meaning |
|---|---|
| `would_add` | The collection is absent and **will** be appended. |
| `already_present` | Nothing to do — the merge is idempotent. |
| `rule_not_found` | ⚠️ **No rule matches that name.** The apply will change nothing and still succeed. |
| `collection_not_found` | ⚠️ The collection does not exist — the API rejects the write (HTTP 400). |
| `collection_invalid_name` | ⚠️ The collection name uses characters this endpoint forbids — HTTP 400. |

> **⚠️ RBAC collections cannot be attached to runtime rules.**
> This endpoint requires `add_collection` to already exist **and** match
> `^[A-Za-z0-9_:-]+$` — no spaces, no parentheses. Collections created by the
> RBAC module are named `<resource-list> - Access Group (RBAC)`, which contains
> both, so the API always rejects them here. This is a Compute API restriction,
> not a module limitation. Use a collection whose name satisfies the charset rule.

`rule_not_found` is the one to watch: it is a *green run that did nothing*. The
workflow raises a ⚠️ annotation at the top of the run summary for it, so you
don't have to spot it by reading JSON.

It also prints `existing_collections`, so you can confirm the append is additive
and won't disturb what's already attached.

### Step 4 — Apply (gated)

**Run workflow** → ✅ check `apply` → an approver approves the `test-tenant`
deployment → the append runs.

**Safety properties:**

- **Idempotent** — re-adding an existing collection is a no-op
- **Non-destructive** — existing collections on the rule are preserved
- **Exact-match** — a name that matches nothing reports no match; it never creates a rule

---

## Scope

`-target=module.compute_runtime_policies` — RBAC resources aren't evaluated here
and can't be changed from this workflow.

## Setup requirements

| Secret | Notes |
|---|---|
| `PRISMACLOUD_API_URL` | Tenant API host |
| `PRISMACLOUD_USERNAME` | Access key UUID (reused for Compute) |
| `PRISMACLOUD_PASSWORD` | Secret key (reused for Compute) |
| `PRISMA_COMPUTE_CONSOLE_URL` | **Must include the path prefix**, e.g. `https://us-east1.cloud.twistlock.com/us-2-158320372` — a host-only URL returns 404 |

Plus the **`test-tenant`** Environment with a required reviewer (for apply).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `authentication failed` (HTTP 500) | Expired or wrong access key. Refresh the secrets. |
| `404` on every call | `PRISMA_COMPUTE_CONSOLE_URL` is missing its path prefix. |
| Listing shows `(unavailable)` | Listing was disabled, or the plan failed earlier in the job. |
| `Argument list too long` | Should not occur — payloads are passed via files (`--slurpfile`). Report it if you see it. |
| Association reports no match | `policy_rule_name` doesn't exactly match a live rule. Re-run the listing. |

## More detail

Module internals, the three listing directions, and the read-merge-write
mechanism: [`terraform/modules/compute-runtime-policies/README.md`](../../../terraform/modules/compute-runtime-policies/README.md)

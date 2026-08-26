# Workflow 2 — Compute Runtime Policies

**Workflow file:** [`../compute-runtime-policies.yml`](../compute-runtime-policies.yml) · **Actions name:** `2. Compute Runtime Policies`

Two capabilities for Prisma Cloud **Compute** runtime policies (Container + Host):

- **List** (read-only) — see which rules exist and where they apply
- **Apply** (gated) — attach an RBAC collection to an **existing** rule, appending only, never creating/redefining/deleting a policy

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

Cluster resolution walks cluster → collections that specifically select it → rules. Wildcard (`*`/`All`) collections are excluded.

## Attaching a collection to a rule

### Step 1 — Find the rule name

Run the listing first. `policy_rule_name` must match an existing rule exactly.

### Step 2 — Declare the association

`terraform/config/compute-runtime-policies.yaml` (git-ignored; copy from [the example](../../../terraform/config/compute-runtime-policies.example.yaml)):

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

Runs automatically on every run, including pushes and PRs. Open the run → **Plan (and list)** job → **"Association dry run (what the apply would actually change)"**.

**Read this step, not the plan.** The Terraform plan only says `1 to add` (bookkeeping for the `null_resource`); the dry run queries the live policy:

| Status | Meaning |
|---|---|
| `would_add` | Collection absent, will be appended. |
| `already_present` | Nothing to do. |
| `rule_not_found` | No matching rule — apply changes nothing but still succeeds. |
| `collection_not_found` | Collection doesn't exist — API rejects (HTTP 400). |
| `collection_invalid_name` | Name uses forbidden characters — HTTP 400. |
| `collection_cluster_scoped_on_host` | Cluster-scoped collection on a HOST rule — HTTP 400. |

> HOST rules require the collection's `clusters` to be empty or `["*"]` — hosts aren't cluster members. Use `clusters: ["*"]` for host associations.

> RBAC collections can't attach to runtime rules — `add_collection` must match `^[A-Za-z0-9_:-]+$`, and RBAC-spawned collections (`<resource-list> - Access Group (RBAC)`) contain spaces/parentheses.

`rule_not_found` is a green run that did nothing — the workflow raises a warning annotation for it. `existing_collections` is also printed, confirming the append is additive.

### Step 4 — Apply (gated)

**Run workflow** → tick `apply` → approver approves the `test-tenant` deployment → append runs.

Idempotent, non-destructive, exact-match only.

## Scope

`-target=module.compute_runtime_policies` — RBAC resources aren't evaluated here.

## Setup requirements

| Secret | Notes |
|---|---|
| `PRISMACLOUD_API_URL` | Tenant API host |
| `PRISMACLOUD_USERNAME` | Access key UUID (reused for Compute) |
| `PRISMACLOUD_PASSWORD` | Secret key (reused for Compute) |
| `PRISMA_COMPUTE_CONSOLE_URL` | Must include path prefix, e.g. `https://us-east1.cloud.twistlock.com/us-2-158320372` — host-only URL returns 404 |

Plus the **`test-tenant`** Environment with a required reviewer (for apply).

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `authentication failed` (HTTP 500) | Expired or wrong access key. |
| `404` on every call | `PRISMA_COMPUTE_CONSOLE_URL` missing its path prefix. |
| Listing shows `(unavailable)` | Listing disabled, or plan failed earlier. |
| `Argument list too long` | Should not occur — payloads passed via files. Report if seen. |
| Association reports no match | `policy_rule_name` doesn't exactly match a live rule. |

## More detail

Module internals, the three listing directions, and the read-merge-write mechanism: [`terraform/modules/compute-runtime-policies/README.md`](../../../terraform/modules/compute-runtime-policies/README.md)

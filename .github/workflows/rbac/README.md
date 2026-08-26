# Workflow 1 — RBAC (teams)

**Workflow file:** [`../rbac.yml`](../rbac.yml) · **Actions name:** `1. RBAC (teams)`

Creates and maintains per-team Prisma Cloud RBAC artifacts — Account Groups, Resource Lists, Roles, optional Service Accounts and Alert Rules — bound to one shared Permission Group. Driven by [`terraform/config/teams.yaml`](../../../terraform/config/teams.yaml).

## Step 1 — Run a plan (safe, do this first)

1. **Actions** tab → **1. RBAC (teams)** in the sidebar
2. **Run workflow** → leave `apply` **unchecked** → **Run workflow**
3. Open the run → click the **Plan** job → read **"Show plan (human-readable)"**

| Symbol | Meaning |
|---|---|
| `+ create` | Something new will be made |
| `~ update` | Something existing will be modified |
| `- destroy` | Something will be **deleted** — stop and ask if unexpected |
| `No changes` | Tenant already matches the config |

Pushes and PRs run plan only, never apply.

## Step 2 — Change what a team gets

Edit `terraform/config/teams.yaml`, commit on a branch, open a PR. The plan posts as a PR comment.

> `teams.yaml` is git-ignored. Zero team resources in the plan means it's missing on the runner.

## Step 3 — Review the plan on the PR

- Does it touch only what you intended?
- Any unexpected `- destroy`?
- Renaming a team is destroy + create, not a rename.

Merging does not apply.

## Step 4 — Apply (gated)

1. **Actions** → **1. RBAC (teams)** → **Run workflow**
2. Tick **`apply`** → Run
3. **Plan** runs, then **Apply (gated)** pauses for approval
4. An approver opens the run → **Review deployments** → **Approve**
5. Verify in the Prisma Cloud console

## Scope

Restricted with `-target` to:
- `prismacloud_permission_group.app_owner_readonly_singleton`
- `module.prisma_cloud_rbac`

Compute runtime policies and tenant inventory belong to workflows 2 and 3.

## Setup requirements

| Secret | Example |
|---|---|
| `PRISMACLOUD_API_URL` | `api.prismacloud.io` |
| `PRISMACLOUD_USERNAME` | access key UUID |
| `PRISMACLOUD_PASSWORD` | secret key |

**Environment:** `test-tenant` (Settings → Environments) with a required reviewer — that's what gates the apply.

## State: no backend

No `backend` block — state is local to the CI runner and destroyed with it. The apply job re-plans rather than reusing the plan job's plan file.

Every run starts believing the tenant is empty, so a second apply tries to *create* existing artifacts and the API rejects with `object already exists`.

**Mitigation:** [`terraform/import.tf`](../../../terraform/import.tf) — `import` blocks that adopt existing artifacts. A healthy plan against an already-provisioned team reads:

```
Plan: 5 to import, 2 to add, 0 to change, 0 to destroy.
```

If those same artifacts show under `to add` instead, an import block is missing or wrong — stop, the apply will fail.

**New team:** its artifacts aren't in `import.tf` yet. First apply creates them; add their IDs afterward or the next run collides. File header has the lookup API calls.

**Never commit a state file.** `prismacloud_user_profile.service_account`'s secret key is written to state in plaintext (`sensitive = true` only redacts CLI output). A committed key means rotating the service account.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `object already exists` on apply | Artifact exists in the tenant, no `import` block. Add it to [`terraform/import.tf`](../../../terraform/import.tf). |
| Plan says `to add` for a provisioned team | Same cause. Do not apply. |
| `Cannot import non-existent remote object` | ID in `import.tf` is stale or from a different tenant. Re-read via the API commands in that file's header. |
| Plan shows no team resources | `teams.yaml` is git-ignored and absent on the runner. |
| Apply never starts | `apply` left unchecked, or nobody approved the `test-tenant` deployment. |
| `expired_access_key` | Refresh `PRISMACLOUD_USERNAME` / `PRISMACLOUD_PASSWORD`. |

## More detail

Module internals and per-team inputs: [`terraform/modules/rbac/README.md`](../../../terraform/modules/rbac/README.md)

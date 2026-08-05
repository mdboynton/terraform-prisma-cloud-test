# Workflow 1 — RBAC (teams)

**Workflow file:** [`../rbac.yml`](../rbac.yml) · **Actions name:** `1. RBAC (teams)`

Creates and maintains per-team Prisma Cloud RBAC artifacts — Account Groups,
Resource Lists, Roles, optional Service Accounts and Alert Rules — all bound to
one shared Permission Group. Driven by
[`terraform/config/teams.yaml`](../../../terraform/config/teams.yaml).

**Can it change the tenant?** Yes — behind an approval gate.

---

## First, the 30-second mental model

Terraform reads config files in this repo, compares them to what actually
exists in the tenant, and makes the tenant match the files. Two verbs:

- **Plan** — "show me what *would* change." Read-only. Always safe.
- **Apply** — "actually make the change." Gated behind approval here.

**Pushing never applies anything.** Pushes and PRs run plan only.

---

## Step 1 — Run a plan (safe, do this first)

1. **Actions** tab → **1. RBAC (teams)** in the sidebar
2. **Run workflow** → leave `apply` **unchecked** → **Run workflow**
3. Open the run → click the **Plan** job → read **"Show plan (human-readable)"**

Terraform's symbols:

| Symbol | Meaning |
|---|---|
| `+ create` | Something new will be made |
| `~ update` | Something existing will be modified |
| `- destroy` | Something will be **deleted** — stop and ask if unexpected |
| `No changes` | Tenant already matches the config |

Do this once before changing anything so you know what "normal" looks like.

## Step 2 — Change what a team gets

Team definitions live in `terraform/config/teams.yaml`. Edit it, commit on a
branch, and open a pull request. The plan is posted **as a comment on the PR**.

> **`teams.yaml` is git-ignored.** It won't exist on the runner unless it was
> force-added (`git add -f`). If your plan shows zero team resources, that's why.

## Step 3 — Review the plan on the PR

- Does it touch only what you intended?
- Any unexpected `- destroy`?
- Renaming a team is a destroy + create, not a rename — check carefully.

Merge when it looks right. **Merging does not apply.**

## Step 4 — Apply (gated)

1. **Actions** → **1. RBAC (teams)** → **Run workflow**
2. Tick **`apply`** → Run
3. **Plan** runs, then **Apply (gated)** pauses for approval
4. An approver opens the run → **Review deployments** → **Approve**
5. Verify in the Prisma Cloud console

---

## Scope

This workflow is restricted with `-target` to:

- `prismacloud_permission_group.app_owner_readonly_singleton`
- `module.prisma_cloud_rbac`

Compute runtime policies and tenant inventory belong to workflows 2 and 3 and
cannot be changed from here.

## Setup requirements

**Secrets** (Settings → Secrets and variables → Actions):

| Secret | Example |
|---|---|
| `PRISMACLOUD_API_URL` | `api.prismacloud.io` |
| `PRISMACLOUD_USERNAME` | access key UUID |
| `PRISMACLOUD_PASSWORD` | secret key |

**Environment:** create one named **`test-tenant`** (Settings → Environments)
with a **required reviewer**. That is what pauses the apply. Without it the job
still runs — but with no gate.

## State: there is no backend (read this before your second apply)

This repo has **no `backend` block**, so Terraform state is local to whichever
CI runner performed the apply and is destroyed with it. Nothing persists between
runs. It is also why the apply job re-plans rather than applying the plan file
from the plan job — that artifact would reference state this job doesn't have.

**The consequence:** every run starts believing the tenant is empty. On a second
apply Terraform tries to *create* artifacts that already exist, and the API
rejects the duplicate with `object already exists`.

**The current mitigation** is [`terraform/import.tf`](../../../terraform/import.tf):
`import` blocks that tell Terraform "this already exists, adopt it". A plan
against an already-provisioned team should read:

```
Plan: 5 to import, 2 to add, 0 to change, 0 to destroy.
```

`to import` is the healthy signal. If you instead see those same artifacts under
`to add`, an import block is missing or its address is wrong — **stop**, because
the apply will fail on the duplicate.

**When you create a new team,** its artifacts won't be in `import.tf` yet. The
first apply creates them; add their IDs to `import.tf` afterwards or the *next*
run will collide. The file header has the exact API calls to look the IDs up.

**Never commit a state file to this repo.** Terraform writes sensitive
attributes to state in **plaintext**, including
`prismacloud_user_profile.service_account`'s secret key — which the API returns
only once. `sensitive = true` redacts CLI output, not the state file. Git
history is permanent, so a committed key means rotating the service account.

**The real fix** is a remote backend (S3 + DynamoDB, or Terraform Cloud): state
persists, it's encrypted, and it's locked against two applies running at once.
Import blocks are a stopgap that only covers IDs someone remembered to write
down.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `object already exists` on apply | The artifact exists in the tenant but has no `import` block. Add it to [`terraform/import.tf`](../../../terraform/import.tf) — see the state section above. |
| Plan says `to add` for a team you already provisioned | Same cause. Do not apply; the create will be rejected. |
| `Cannot import non-existent remote object` | An ID in `import.tf` is stale or from a different tenant. Re-read it from the API using the commands in that file's header. |

| Symptom | Cause / fix |
|---|---|
| Plan shows no team resources | `teams.yaml` is git-ignored and absent on the runner. |
| `object already exists` | An artifact of that name exists in the tenant. Adopt it (see `existing_permission_group_id`) or remove it in the UI. |
| Apply never starts | `apply` was left unchecked, or nobody approved the `test-tenant` deployment. |
| `expired_access_key` | Credentials expired — refresh `PRISMACLOUD_USERNAME` / `PRISMACLOUD_PASSWORD`. |

## More detail

Module internals and per-team inputs: [`terraform/modules/rbac/README.md`](../../../terraform/modules/rbac/README.md)

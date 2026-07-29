# Workflow 1 — RBAC (teams)

**Workflow file:** [`../rbac.yml`](../rbac.yml) · **Actions name:** `1. RBAC (teams)`

Creates and maintains per-team Prisma Cloud RBAC artifacts — Account Groups,
Resource Lists, Roles, optional Service Accounts and Alert Rules — all bound to
one shared Permission Group. Driven by
[`terraform/config/teams.yaml`](../../../terraform/config/teams.yaml).

**Can it change the tenant?** ✅ Yes — behind an approval gate.

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

> ⚠️ **`teams.yaml` is git-ignored.** It won't exist on the runner unless it was
> force-added (`git add -f`). If your plan shows zero team resources, that's why.

## Step 3 — Review the plan on the PR

- Does it touch only what you intended?
- Any unexpected `- destroy`?
- Renaming a team is a destroy + create, not a rename — check carefully.

Merge when it looks right. **Merging does not apply.**

## Step 4 — Apply (gated)

1. **Actions** → **1. RBAC (teams)** → **Run workflow**
2. ✅ Check **`apply`** → Run
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

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Plan shows no team resources | `teams.yaml` is git-ignored and absent on the runner. |
| `object already exists` | An artifact of that name exists in the tenant. Adopt it (see `existing_permission_group_id`) or remove it in the UI. |
| Apply never starts | `apply` was left unchecked, or nobody approved the `test-tenant` deployment. |
| `expired_access_key` | Credentials expired — refresh `PRISMACLOUD_USERNAME` / `PRISMACLOUD_PASSWORD`. |

## More detail

Module internals and per-team inputs: [`terraform/modules/rbac/README.md`](../../../terraform/modules/rbac/README.md)

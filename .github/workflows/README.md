# CI Workflows

Three workflows, one per area of Prisma Cloud configuration. Each has its own
step-by-step guide in the folder beside it.

| # | Workflow | Purpose | Changes the tenant? | Guide |
|---|---|---|---|---|
| 1 | [`rbac.yml`](rbac.yml) | Per-team RBAC: Account Groups, Resource Lists, Roles, Service Accounts, Alert Rules | Yes — approval gated | [rbac/README.md](rbac/README.md) |
| 2 | [`compute-runtime-policies.yml`](compute-runtime-policies.yml) | List Compute runtime rules; attach a collection to an existing rule | Yes — approval gated | [compute-runtime-policies/README.md](compute-runtime-policies/README.md) |
| 3 | [`tenant-inventory.yml`](tenant-inventory.yml) | List tenant-wide settings and configuration | **No** — read-only by construction | [tenant-inventory/README.md](tenant-inventory/README.md) |

## Which one do I want?

- **Onboarding a team, or changing what a team can see** → workflow 1
- **Seeing which runtime rules cover a cluster, or attaching a collection to a rule** → workflow 2
- **Just looking at tenant settings, integrations, reports, trusted IPs** → workflow 3

## Rules that apply to all of them

- **Plan is always safe.** It shows what *would* change and writes nothing.
- **Pushing never applies.** Pushes and PRs run plan only.
- **Apply is deliberate.** It requires a manual run with `apply` checked, *plus*
  approval on the `test-tenant` Environment. Two separate actions.
- **Workflow 3 has no apply at all** — its module contains zero `resource`
  blocks, so there is nothing to gate.

## Why they're separate

Each workflow uses `-target` so it only evaluates its own resources. That keeps
plans readable (no unrelated pending changes as noise) and means the RBAC
pipeline can't modify compute policies, or vice versa. Read-only listing is
split out entirely so you can inspect the tenant without touching a
change-capable pipeline.

## Shared setup

**Secrets** — Settings → Secrets and variables → Actions:

| Secret | Used by | Notes |
|---|---|---|
| `PRISMACLOUD_API_URL` | all | e.g. `api.prismacloud.io` |
| `PRISMACLOUD_USERNAME` | all | Access key UUID |
| `PRISMACLOUD_PASSWORD` | all | Secret key |
| `PRISMA_COMPUTE_CONSOLE_URL` | 2 | **Include the path prefix**, e.g. `https://us-east1.cloud.twistlock.com/us-2-158320372` |

**Environment** — create **`test-tenant`** (Settings → Environments) with a
**required reviewer**. This is the approval gate for workflows 1 and 2. Without
it those apply jobs still run, but unguarded.

## A note on state

There is no remote backend, so Terraform state is local to each job. This is why
apply jobs re-plan rather than applying a saved plan file from the plan job, and
why `-target` is used to keep each workflow in its own lane. Moving to a remote
backend would be the natural next step if these need to share state or run
concurrently.

## Git-ignored config

Two config files are git-ignored and therefore **absent on the runner** unless
force-added:

- `terraform/config/teams.yaml` — workflow 1 plans zero team resources without it
- `terraform/config/compute-runtime-policies.yaml` — workflow 2 is a no-op without it

Each has a committed `.example.yaml` to copy from.

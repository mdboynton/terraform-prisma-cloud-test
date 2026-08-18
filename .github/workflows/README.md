# CI Workflows

Nine workflows, one per area of Prisma Cloud configuration. Each has its own
step-by-step guide in the folder beside it.

| # | Workflow | Purpose | Changes the tenant? | Guide |
|---|---|---|---|---|
| 1 | [`rbac.yml`](rbac.yml) | Per-team RBAC: Account Groups, Resource Lists, Roles, Service Accounts, Alert Rules | Yes — approval gated | [rbac/README.md](rbac/README.md) |
| 2 | [`compute-runtime-policies.yml`](compute-runtime-policies.yml) | List Compute runtime rules; attach a collection to an existing rule | Yes — approval gated | [compute-runtime-policies/README.md](compute-runtime-policies/README.md) |
| 3 | [`tenant-inventory.yml`](tenant-inventory.yml) | List tenant-wide settings and configuration | **No** — read-only by construction | [tenant-inventory/README.md](tenant-inventory/README.md) |
| 4 | [`access-audit.yml`](access-audit.yml) | Audit roles, users and permission groups; surface the rows a review acts on | **No** — read-only by construction | [access-audit/README.md](access-audit/README.md) |
| 5 | [`drift-detection.yml`](drift-detection.yml) | Daily "did anything change in the tenant?" check; opens an issue when it did | **No** — only commits a snapshot to this repo | [drift-detection/README.md](drift-detection/README.md) |
| 6 | [`alert-summary.yml`](alert-summary.yml) | Count alerts for a CSPM Collection by severity, and list the critical ones | **No** — read-only by construction | [alert-summary/README.md](alert-summary/README.md) |
| 7 | [`compute-alert-summary.yml`](compute-alert-summary.yml) | Count Compute runtime incidents and image CVEs for a **Compute** collection | **No** — read-only by construction | [compute-alert-summary/README.md](compute-alert-summary/README.md) |
| 8 | [`runtime-grace-digest.yml`](runtime-grace-digest.yml) | Which runtime rules are **still firing**, grouped by rule, scope and account | **No** — read-only by construction | [runtime-grace-digest/README.md](runtime-grace-digest/README.md) |
| 9 | [`runtime-rule-effects.yml`](runtime-rule-effects.yml) | Which firing rules are **still only watching**; raise one effect site to prevent/block | Yes — approval gated | [runtime-rule-effects/README.md](runtime-rule-effects/README.md) |

## Which one do I want?

- **Onboarding a team, or changing what a team can see** → workflow 1
- **Seeing which runtime rules cover a cluster, or attaching a collection to a rule** → workflow 2
- **Just looking at tenant settings, integrations, reports, trusted IPs** → workflow 3
- **Reviewing who has access — stale accounts, unassigned roles** → workflow 4
- **Finding out what changed since yesterday, including console-made changes** → workflow 5
- **Seeing how many alerts a team's collection has** → workflow 6
- **Seeing a team's Compute runtime incidents and image CVEs** → workflow 7
- **Finding which runtime rules keep firing, to decide what to escalate** → workflow 8
- **Seeing which firing rules are still only alerting, and blocking one** → workflow 9

### 6 or 7?

They read **two unrelated collection systems**, and the numbers are not
comparable — never add one to the other.

- The collection is in **Compute → Manage → Collections**, or its name ends in
  `- Access Group (RBAC)` → **workflow 7**
- The collection is in **Settings → Collections** and you want posture alerts →
  **workflow 6**
- The tenant has **no cloud accounts onboarded** → workflow 6 has nothing to
  scope by; use **workflow 7**

## Rules that apply to all of them

- **Plan is always safe.** It shows what *would* change and writes nothing.
- **Pushing never applies.** Pushes and PRs run plan only.
- **Apply is deliberate.** It requires a manual run with `apply` checked (in
  workflow 9, the word `APPLY` typed in full), *plus* approval on the
  `test-tenant` Environment. Two separate actions.
- **Workflows 3, 4, 5, 6, 7 and 8 have no apply at all** — their modules contain
  zero `resource` blocks, so there is nothing to gate.
- **Workflow 9 is the only one that changes enforcement on a live security
  policy.** Its write runs in a provisioner, so `terraform plan` cannot trigger
  it, and its apply job re-validates against live state after approval —
  approving a gate does not re-check a plan.

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
| `PRISMA_COMPUTE_CONSOLE_URL` | 1, 2, 7 | **Include the path prefix**, e.g. `https://us-east1.cloud.twistlock.com/us-2-158320372`. Without it, auth "succeeds" and returns an empty token. |

**Environment** — create **`test-tenant`** (Settings → Environments) with a
**required reviewer**. This is the approval gate for workflows 1 and 2. Without
it those apply jobs still run, but unguarded.

## A note on state

There is no remote backend, so Terraform state is local to each job. This is why
apply jobs re-plan rather than applying a saved plan file from the plan job, and
why `-target` is used to keep each workflow in its own lane. Moving to a remote
backend would be the natural next step if these need to share state or run
concurrently.

It is also why workflow 5 compares **snapshots** rather than running
`terraform plan` and reading the diff: with no prior state to compare against,
every run would look like a first run. Snapshots additionally catch changes to
objects Terraform does not manage — which is most of this tenant.

## Git-ignored config

Two config files are git-ignored and therefore **absent on the runner** unless
force-added:

- `terraform/config/teams.yaml` — workflow 1 plans zero team resources without it
- `terraform/config/compute-runtime-policies.yaml` — workflow 2 is a no-op without it

Each has a committed `.example.yaml` to copy from.

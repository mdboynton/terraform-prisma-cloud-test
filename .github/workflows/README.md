# CI Workflows

Nine workflows, one per area of Prisma Cloud configuration.

| # | Workflow | Purpose | Changes the tenant? | Guide |
|---|---|---|---|---|
| 1 | [`rbac.yml`](rbac.yml) | Per-team RBAC: Account Groups, Resource Lists, Roles, Service Accounts, Alert Rules | Yes — approval gated | [rbac/README.md](rbac/README.md) |
| 2 | [`compute-runtime-policies.yml`](compute-runtime-policies.yml) | List Compute runtime rules; attach a collection to an existing rule | Yes — approval gated | [compute-runtime-policies/README.md](compute-runtime-policies/README.md) |
| 3 | [`tenant-inventory.yml`](tenant-inventory.yml) | List tenant-wide settings and configuration | No | [tenant-inventory/README.md](tenant-inventory/README.md) |
| 4 | [`access-audit.yml`](access-audit.yml) | Audit roles, users and permission groups | No | [access-audit/README.md](access-audit/README.md) |
| 5 | [`drift-detection.yml`](drift-detection.yml) | Daily tenant-change check; opens an issue when drift is found | No — commits a snapshot to this repo | [drift-detection/README.md](drift-detection/README.md) |
| 6 | [`alert-summary.yml`](alert-summary.yml) | Count alerts for a CSPM Collection by severity | No | [alert-summary/README.md](alert-summary/README.md) |
| 7 | [`compute-alert-summary.yml`](compute-alert-summary.yml) | Count Compute runtime incidents and image CVEs for a Compute collection | No | [compute-alert-summary/README.md](compute-alert-summary/README.md) |
| 8 | [`runtime-grace-digest.yml`](runtime-grace-digest.yml) | Which runtime rules are still firing | No to the tenant — can send email (gated) | [runtime-grace-digest/README.md](runtime-grace-digest/README.md) |
| 9 | [`runtime-rule-effects.yml`](runtime-rule-effects.yml) | Which firing rules are still only alerting; raise one effect site to prevent/block | Yes — approval gated | [runtime-rule-effects/README.md](runtime-rule-effects/README.md) |

## Which one do I want?

- Onboarding a team, or changing what a team can see → 1
- Seeing which runtime rules cover a cluster, or attaching a collection to a rule → 2
- Tenant settings, integrations, reports, trusted IPs → 3
- Access review — stale accounts, unassigned roles → 4
- What changed since yesterday → 5
- Alerts for a CSPM collection → 6
- Compute runtime incidents and image CVEs for a collection → 7
- Which runtime rules keep firing → 8
- Which firing rules are still only alerting, and blocking one → 9

### 6 or 7?

Two unrelated collection systems — never compare the numbers.

- Collection is in **Compute → Manage → Collections**, or its name ends in `- Access Group (RBAC)` → 7
- Collection is in **Settings → Collections** → 6
- No cloud accounts onboarded → 6 has nothing to scope by; use 7

## Rules that apply to all of them

- Plan is always safe; pushes and PRs plan only.
- Apply requires a manual dispatch with `apply` checked (workflow 9: type `APPLY`) plus approval on the `test-tenant` Environment.
- Workflows 3–8 have no apply — zero `resource` blocks.
- Workflow 9's write runs in a provisioner (plan can't trigger it); its apply job re-validates against live state after approval.

## Shared setup

**Secrets** — Settings → Secrets and variables → Actions:

| Secret | Used by | Notes |
|---|---|---|
| `PRISMACLOUD_API_URL` | all | e.g. `api.prismacloud.io` |
| `PRISMACLOUD_USERNAME` | all | Access key UUID |
| `PRISMACLOUD_PASSWORD` | all | Secret key |
| `PRISMA_COMPUTE_CONSOLE_URL` | 1, 2, 7 | Include the path prefix, e.g. `https://us-east1.cloud.twistlock.com/us-2-158320372`. |

**Environment** — create `test-tenant` (Settings → Environments) with a required reviewer, for workflows 1 and 2.

## A note on state

No remote backend — state is local per job. Apply jobs re-plan rather than reuse a saved plan file. `-target` keeps each workflow in its own lane. Workflow 5 compares snapshots rather than reading a plan diff, since there's no prior state.

## Git-ignored config

- `terraform/config/teams.yaml` — workflow 1 plans zero team resources without it
- `terraform/config/compute-runtime-policies.yaml` — workflow 2 is a no-op without it

Each has a committed `.example.yaml`.

# terraform-prisma-cloud-modules

Terraform modules for managing a Prisma Cloud tenant — per-team RBAC, Compute runtime policy associations, read-only tenant inventory, access auditing, and daily drift detection. Driven from GitHub Actions; edit config, review the plan, approve the apply.

## Workflows — start here

Nine workflows in the **Actions** tab, each with its own guide:

| # | Workflow | Use it to | Changes the tenant? |
|---|---|---|---|
| 1 | [**RBAC (teams)**](.github/workflows/rbac/README.md) | Onboard a team; change what a team can see | Yes — approval gated |
| 2 | [**Compute Runtime Policies**](.github/workflows/compute-runtime-policies/README.md) | See which runtime rules cover a cluster; attach a collection to a rule | Yes — approval gated |
| 3 | [**Tenant Inventory**](.github/workflows/tenant-inventory/README.md) | Look at tenant settings, integrations, reports, trusted IPs | No |
| 4 | [**Access Audit**](.github/workflows/access-audit/README.md) | Review who has access: stale accounts, unassigned roles, permission groups | No |
| 5 | [**Drift Detection**](.github/workflows/drift-detection/README.md) | Find out what changed since yesterday, including console-made changes | No — only commits a snapshot to this repo |
| 6 | [**Alert Summary**](.github/workflows/alert-summary/README.md) | Count alerts for a CSPM Collection by severity, list the critical ones | No |
| 7 | [**Compute Alert Summary**](.github/workflows/compute-alert-summary/README.md) | Count Compute runtime incidents and image CVEs for a Compute collection | No |
| 8 | [**Runtime Grace Digest**](.github/workflows/runtime-grace-digest/README.md) | See which runtime rules are still firing | No to the tenant — can send grace warning emails, gated |
| 9 | [**Runtime Rule Effects**](.github/workflows/runtime-rule-effects/README.md) | See which firing rules are still only watching; turn one into a blocking rule | Yes — approval gated |

Full index: [`.github/workflows/README.md`](.github/workflows/README.md).

## Modules

Root module reads [`terraform/config/teams.yaml`](terraform/config/teams.yaml) and instantiates [`rbac`](terraform/modules/rbac/README.md) once per entry — Account Group(s), Resource List(s), Role, optional Service Account, optional CSPM Alert Rule, bound to a shared Permission Group.

It also reads [`terraform/config/compute-runtime-policies.yaml`](terraform/config/compute-runtime-policies.yaml) and runs [`compute-runtime-policies`](terraform/modules/compute-runtime-policies/README.md), which attaches an RBAC Collection to existing Compute runtime policy rules (Container + Host) — appends only, never creates/redefines.

[`tenant-inventory`](terraform/modules/tenant-inventory/README.md) lists tenant-level settings — enterprise settings, trusted login/alert IPs, integrations, reports, notification templates, anomaly settings. Read-only by construction (`data` blocks only).

[`access-audit`](terraform/modules/access-audit/README.md) reads roles, user profiles, permission groups; derives unassigned roles, never-logged-in accounts, stale logins, users with no roles. Read-only by construction; feeds [drift detection](.github/workflows/drift-detection/README.md) via its username-hashing.

## Layout

| Path | Description |
|---|---|
| [`terraform/`](terraform/) | Root module. Run `terraform init/plan/apply` here. |
| [`terraform/modules/rbac/`](terraform/modules/rbac/) | RBAC artifacts (Account Group, Resource List, Role, Service Account, Alert Rule). [README](terraform/modules/rbac/README.md) |
| [`terraform/modules/compute-runtime-policies/`](terraform/modules/compute-runtime-policies/) | Attach an RBAC Collection to existing Compute runtime policy rules. [README](terraform/modules/compute-runtime-policies/README.md) |
| [`terraform/modules/tenant-inventory/`](terraform/modules/tenant-inventory/) | Read-only tenant-level settings/config. [README](terraform/modules/tenant-inventory/README.md) |
| [`terraform/modules/access-audit/`](terraform/modules/access-audit/) | Read-only audit of roles, user profiles, permission groups. [README](terraform/modules/access-audit/README.md) |
| [`terraform/modules/alert-summary/`](terraform/modules/alert-summary/) | Read-only alert counts scoped to a CSPM Collection, plus opt-in detail. [README](terraform/modules/alert-summary/README.md) |
| [`terraform/modules/compute-alert-summary/`](terraform/modules/compute-alert-summary/) | Read-only Compute runtime incident and image CVE counts for a Compute collection. [README](terraform/modules/compute-alert-summary/README.md) |
| [`terraform/modules/runtime-grace-digest/`](terraform/modules/runtime-grace-digest/) | Read-only digest of runtime rules still producing incidents. [README](terraform/modules/runtime-grace-digest/README.md) |
| [`terraform/modules/runtime-rule-effects/`](terraform/modules/runtime-rule-effects/) | Reports enforcement effect of firing runtime rules; behind a typed confirmation and approval, raises one effect site to `prevent`/`block`. The only module that changes enforcement. [README](terraform/modules/runtime-rule-effects/README.md) |
| [`scripts/drift/`](scripts/drift/) | `snapshot.sh` (plan JSON → fingerprint) and `diff.sh` (baseline vs current → markdown + exit code). Used by workflow 5. |
| [`terraform/config/teams.yaml`](terraform/config/teams.yaml) | Config file, one entry per team. Gitignored; absent = zero resources. |
| [`terraform/config/teams.example.yaml`](terraform/config/teams.example.yaml) | Annotated example. Copy to `teams.yaml`. |
| [`terraform/config/compute-runtime-policies.yaml`](terraform/config/compute-runtime-policies.yaml) | Runtime-policy associations. Gitignored; absent = no-op. `git add -f` for CI. |
| [`terraform/config/compute-runtime-policies.example.yaml`](terraform/config/compute-runtime-policies.example.yaml) | Annotated example. Copy to `compute-runtime-policies.yaml`. |
| [`terraform/testing.tf`](terraform/testing.tf) | Commented-out sentinel module for manual smoke tests. |

## Quick start

```bash
cd terraform/

source .env

terraform init
terraform validate

terraform plan -out=output.tfplan
terraform show -json output.tfplan | jq .resource_changes
terraform apply output.tfplan
```

Empty/absent config = zero resources on plan. Add entries to `teams.yaml` (see [`teams.example.yaml`](terraform/config/teams.example.yaml)).

## Provider configuration

```bash
export PRISMACLOUD_API_URL=<tenant-api-host>   # e.g. api.prismacloud.io
export PRISMACLOUD_USERNAME=<access-key-uuid>
export PRISMACLOUD_PASSWORD=<secret-key>
```

Copy into `terraform/.env`, `source .env` each session. In Actions, set as repository/environment secrets and export before Terraform steps.

## Running from GitHub Actions

See [Workflows](#workflows--start-here) above or [`.github/workflows/README.md`](.github/workflows/README.md).

Setup:

1. Secrets (**Settings → Secrets and variables → Actions**): `PRISMACLOUD_API_URL`, `PRISMACLOUD_USERNAME`, `PRISMACLOUD_PASSWORD`, `PRISMA_COMPUTE_CONSOLE_URL` (workflow 2 only).
2. Create a **`test-tenant`** Environment (**Settings → Environments**) with a required reviewer — the apply gate for workflows 1 and 2.

No remote backend — state is local to each job; apply jobs re-plan instead of reusing the plan job's artifact, and each workflow uses `-target` to stay in its own lane. Sensitive outputs (service-account secret keys) live in state — treat the state file as a secret.

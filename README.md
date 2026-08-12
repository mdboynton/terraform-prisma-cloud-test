# terraform-prisma-cloud-modules

Terraform modules for managing a Prisma Cloud tenant — per-team RBAC, Compute
runtime policy associations, read-only tenant inventory, access auditing, and
daily drift detection. Everything is driven from GitHub Actions; edit config,
review the plan, approve the apply.

## Workflows — start here

Most people interact with this repo through the **Actions** tab. There are seven
workflows, each with its own step-by-step guide:

| # | Workflow | Use it to | Changes the tenant? |
|---|---|---|---|
| 1 | [**RBAC (teams)**](.github/workflows/rbac/README.md) | Onboard a team; change what a team can see | Yes — approval gated |
| 2 | [**Compute Runtime Policies**](.github/workflows/compute-runtime-policies/README.md) | See which runtime rules cover a cluster; attach a collection to a rule | Yes — approval gated |
| 3 | [**Tenant Inventory**](.github/workflows/tenant-inventory/README.md) | Look at tenant settings, integrations, reports, trusted IPs | **No** — read-only by construction |
| 4 | [**Access Audit**](.github/workflows/access-audit/README.md) | Review who has access: stale accounts, unassigned roles, permission groups | **No** — read-only by construction |
| 5 | [**Drift Detection**](.github/workflows/drift-detection/README.md) | Find out what changed since yesterday, including console-made changes | **No** — only commits a snapshot to this repo |
| 6 | [**Alert Summary**](.github/workflows/alert-summary/README.md) | Count alerts for a CSPM Collection by severity, and list the critical ones | **No** — read-only by construction |
| 7 | [**Compute Alert Summary**](.github/workflows/compute-alert-summary/README.md) | Count Compute runtime incidents and image CVEs for a **Compute** collection | **No** — read-only by construction |

Ground rules across all seven: **plan is always safe**, **pushing never
applies**, and an apply needs both a manual run *and* an approval. Workflows 3,
4, 5, 6 and 7 have no apply step at all.

Workflows 6 and 7 are siblings, not alternatives: Prisma has two unrelated
collection systems, and they read one each. Their numbers count different
objects and must not be added together.

New to Terraform? Each guide above starts from first principles — no prior
experience assumed. Overview of all seven:
[`.github/workflows/README.md`](.github/workflows/README.md).

## Modules

The root module reads [`terraform/config/teams.yaml`](terraform/config/teams.yaml)
and instantiates the [`rbac`](terraform/modules/rbac/README.md)
module once per entry. Each entry produces one team's Account Group(s), Resource
List(s), Role, optional Service Account, and optional CSPM Alert Rule, all bound to a
shared Permission Group.

It also reads
[`terraform/config/compute-runtime-policies.yaml`](terraform/config/compute-runtime-policies.yaml)
and runs the
[`compute-runtime-policies`](terraform/modules/compute-runtime-policies/README.md)
module, which **attaches an RBAC Collection to existing Compute runtime policy rules**
(Container + Host) so console-authored policies apply to a team's resources. It does not
create or change the policies themselves — it only appends the collection to a matched
rule, preserving what's already there.

[`tenant-inventory`](terraform/modules/tenant-inventory/README.md)
**lists** tenant-level settings and configuration — enterprise settings, trusted
login/alert IPs, integrations, reports, notification templates and anomaly
settings. It is **read-only by construction**: the module contains only
Terraform `data` blocks and no `resource` blocks, so it cannot change anything
in the tenant. It runs from its own
[Tenant Inventory workflow](.github/workflows/tenant-inventory.yml) with a
`scope` dropdown, separate from the change-capable pipeline.

Finally, [`access-audit`](terraform/modules/access-audit/README.md) reads the
tenant's **access-control** objects — roles, user profiles and permission groups
— and derives the subset of rows an access review acts on: unassigned roles,
never-logged-in accounts, stale logins, users with no roles. It is read-only by
construction on the same basis. Because it can hash usernames (which are email
addresses) it is also the input to
[drift detection](.github/workflows/drift-detection/README.md), which fingerprints
the tenant daily and opens an issue when something changes.

## Layout

| Path | Description |
|---|---|
| [`terraform/`](terraform/) | Root module. Run `terraform init/plan/apply` here. |
| [`terraform/modules/rbac/`](terraform/modules/rbac/) | Deploy RBAC artifacts (Account Group, Resource List, Role, Service Account, Alert Rule). [README](terraform/modules/rbac/README.md) |
| [`terraform/modules/compute-runtime-policies/`](terraform/modules/compute-runtime-policies/) | Attach an RBAC Collection to existing Compute Container/Host runtime policy rules (non-destructive append via the Compute API). [README](terraform/modules/compute-runtime-policies/README.md) |
| [`terraform/modules/tenant-inventory/`](terraform/modules/tenant-inventory/) | **Read-only** listing of tenant-level settings/config (data sources only — cannot write). [README](terraform/modules/tenant-inventory/README.md) |
| [`terraform/modules/access-audit/`](terraform/modules/access-audit/) | **Read-only** audit of roles, user profiles and permission groups, with optional username hashing. [README](terraform/modules/access-audit/README.md) |
| [`terraform/modules/alert-summary/`](terraform/modules/alert-summary/) | **Read-only** alert counts scoped to a CSPM Collection, resolved to its cloud accounts, plus opt-in per-alert detail. [README](terraform/modules/alert-summary/README.md) |
| [`terraform/modules/compute-alert-summary/`](terraform/modules/compute-alert-summary/) | **Read-only** Compute runtime incident and image CVE counts scoped to a **Compute** collection (filtered by name — Compute collections have no id). [README](terraform/modules/compute-alert-summary/README.md) |
| [`scripts/drift/`](scripts/drift/) | `snapshot.sh` (plan JSON → privacy-safe fingerprint) and `diff.sh` (baseline vs current → markdown + exit code). Used by workflow 5. |
| [`terraform/config/teams.yaml`](terraform/config/teams.yaml) | The config file. One entry per team defines its RBAC artifacts. Gitignored; not loaded when absent (a clean plan with zero resources). |
| [`terraform/config/teams.example.yaml`](terraform/config/teams.example.yaml) | Annotated example config. Copy it to `teams.yaml` and edit. |
| [`terraform/config/compute-runtime-policies.yaml`](terraform/config/compute-runtime-policies.yaml) | Runtime-policy associations (which existing rule gets which collection). Gitignored; a no-op when absent. Use `git add -f` to include it in CI. |
| [`terraform/config/compute-runtime-policies.example.yaml`](terraform/config/compute-runtime-policies.example.yaml) | Annotated example. Copy it to `compute-runtime-policies.yaml` and edit. |
| [`terraform/testing.tf`](terraform/testing.tf) | A commented-out sentinel module for end-to-end smoke tests. Manual use only. |

## Quick start

```bash
cd terraform/

# Provider credentials (see Provider configuration below).
source .env

terraform init
terraform validate

# Preview, inspect, then apply.
terraform plan -out=output.tfplan
terraform show -json output.tfplan | jq .resource_changes
terraform apply output.tfplan
```

With the config file empty or absent, `plan` shows zero resources. Add entries to
`teams.yaml` (using [`teams.example.yaml`](terraform/config/teams.example.yaml)
as a reference) to define teams.

## Provider configuration

The provider reads three environment variables:

```bash
export PRISMACLOUD_API_URL=<tenant-api-host>   # e.g. api.prismacloud.io
export PRISMACLOUD_USERNAME=<access-key-uuid>
export PRISMACLOUD_PASSWORD=<secret-key>
```

Copy these into a `.env` file in `terraform/` so you can `source .env` each session.
In GitHub Actions, provide them as repository or environment secrets and export them
before the Terraform steps.

## Running from GitHub Actions

This is the normal way to use the repo — see the three guides linked in
[Workflows](#workflows--start-here) above, or the index at
[`.github/workflows/README.md`](.github/workflows/README.md).

Setup needed once:

1. Add the secrets under **Settings → Secrets and variables → Actions**:
   `PRISMACLOUD_API_URL`, `PRISMACLOUD_USERNAME`, `PRISMACLOUD_PASSWORD`, and
   `PRISMA_COMPUTE_CONSOLE_URL` (workflow 2 only).
2. Create a **`test-tenant`** Environment (**Settings → Environments**) with a
   **required reviewer**. That reviewer approval is the apply gate for
   workflows 1 and 2.

Two things worth knowing:

- **No remote backend is configured**, so state is local to each job. That's why
  apply jobs re-plan instead of reusing the plan job's artifact, and why each
  workflow uses `-target` to stay in its own lane. Adding a remote backend is
  the natural next step if runs need to share state.
- Sensitive outputs (service-account secret keys) live in state — treat the
  state file as a secret and route those values to your secrets store rather
  than logs.

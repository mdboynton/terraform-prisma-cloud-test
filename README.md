# terraform-prisma-cloud-modules

Terraform modules that provision Prisma Cloud RBAC artifacts from a YAML team
registry. Edit the config, run `plan`/`apply`, and the tenant reconciles.

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

Finally, [`tenant-inventory`](terraform/modules/tenant-inventory/README.md)
**lists** tenant-level settings and configuration — enterprise settings, trusted
login/alert IPs, integrations, reports, notification templates and anomaly
settings. It is **read-only by construction**: the module contains only
Terraform `data` blocks and no `resource` blocks, so it cannot change anything
in the tenant. It runs from its own
[Tenant Inventory workflow](.github/workflows/tenant-inventory.yml) with a
`scope` dropdown, separate from the change-capable pipeline.

## Layout

| Path | Description |
|---|---|
| [`terraform/`](terraform/) | Root module. Run `terraform init/plan/apply` here. |
| [`terraform/modules/rbac/`](terraform/modules/rbac/) | Deploy RBAC artifacts (Account Group, Resource List, Role, Service Account, Alert Rule). [README](terraform/modules/rbac/README.md) |
| [`terraform/modules/compute-runtime-policies/`](terraform/modules/compute-runtime-policies/) | Attach an RBAC Collection to existing Compute Container/Host runtime policy rules (non-destructive append via the Compute API). [README](terraform/modules/compute-runtime-policies/README.md) |
| [`terraform/modules/tenant-inventory/`](terraform/modules/tenant-inventory/) | **Read-only** listing of tenant-level settings/config (data sources only — cannot write). [README](terraform/modules/tenant-inventory/README.md) |
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

The modules are designed to run unattended in CI. A workflow reconciles the tenant on
change to `teams.yaml`:

1. Check out the repo.
2. Export `PRISMACLOUD_API_URL`, `PRISMACLOUD_USERNAME`, `PRISMACLOUD_PASSWORD` from secrets.
3. `terraform init`, `terraform plan` (on pull request), `terraform apply` (on merge).

Store Terraform state in a remote backend so CI runs share it. Route the sensitive
outputs (service-account secret keys) to your secrets store rather than logs.

# CI: Terraform (Prisma Cloud RBAC)

[`terraform.yml`](terraform.yml) reconciles the Prisma Cloud **test tenant** from
[`terraform/config/teams.yaml`](../../terraform/config/teams.yaml).

## What it does

| Trigger | Behavior |
|---|---|
| Pull request to `main` / `tuan_test` | `init` + `validate` + `plan` (read-only). Plan is posted as a PR comment and uploaded as an artifact. Never applies. |
| Manual `workflow_dispatch` with `apply=true` | `plan`, then a **gated** `apply` requiring approval via the `test-tenant` Environment. |
| Push to `tuan_test` | `plan`, then a gated `apply` (same approval gate). |

The `apply` job uses `environment: test-tenant`, so it will not run until a required
reviewer approves it in the GitHub UI. That is the manual approval gate.

## Required repository secrets

Set these under **Settings → Secrets and variables → Actions** (or scope them to the
`test-tenant` Environment):

| Secret | Example | Notes |
|---|---|---|
| `PRISMACLOUD_API_URL` | `api.prismacloud.io` | Tenant API host. Must match the provider's URL validation. |
| `PRISMACLOUD_USERNAME` | `<access-key-uuid>` | Access key ID (UUID). |
| `PRISMACLOUD_PASSWORD` | `<secret-key>` | Secret key. Sensitive. |

The `PaloAltoNetworks/prismacloud` provider reads these env vars natively — no
`*.tfvars` are needed for authentication.

## Required GitHub Environment (approval gate)

Create an Environment named **`test-tenant`** (Settings → Environments) and add
yourself as a **Required reviewer**. This is what pauses the `apply` job for manual
approval. Without it, the job still runs but has no gate.

## IMPORTANT: `teams.yaml` is git-ignored

[`terraform/config/teams.yaml`](../../terraform/config/teams.yaml) is listed in
`.gitignore`, so it is **not committed and will not be present on the runner**. With
it absent, [`locals.tf`](../../terraform/locals.tf) falls back to an empty team map
and the plan shows **zero resources** — a safe no-op, but it will not exercise the
modules.

To actually test the `tuan-test` team in CI, choose one:

1. **Force-add the test config on the `tuan_test` branch only** (simplest for a
   throwaway test):
   ```bash
   git add -f terraform/config/teams.yaml
   ```
   Do NOT do this on `main`, and never force-add a config containing real account
   IDs or secrets.

2. **Generate the config in the workflow** from an un-ignored source file (e.g.
   commit `teams.ci.yaml` and copy it to `teams.yaml` in a workflow step). Preferred
   if you want to keep the gitignore rule intact.

## State backend caveat

There is no remote backend configured, so state is **local and ephemeral per run**.
Consequences:

- A `plan` artifact produced by the `plan` job is applied in a separate `apply` job
  that runs a fresh `init` with no shared state — fine for a first create-only smoke
  test, but fragile for iterative applies.
- Nothing persists Terraform state between runs. For anything beyond a one-shot
  smoke test, add a remote backend (e.g. S3 / Terraform Cloud) before relying on
  `apply`.

## Local `.env`

For local runs, `terraform/.env` (git-ignored) holds the same three variables:

```bash
export PRISMACLOUD_API_URL=api.prismacloud.io
export PRISMACLOUD_USERNAME=<access-key-uuid>
export PRISMACLOUD_PASSWORD=<secret-key>
```

`source terraform/.env` before running Terraform locally.

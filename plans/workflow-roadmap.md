# Workflow roadmap

Goal: a one-stop-shop for viewing tenant state and making scoped, reviewable changes
to it — without anyone needing Terraform installed or console admin rights.

Current state: 3 workflows (RBAC, compute runtime policies, tenant inventory).

---

## 0. The dashboard (requested)

**Problem.** Every read today dies with the job. To answer "what integrations do we
have?" you re-run a workflow, expand a step, and read JSON. Nothing is comparable
over time, and nothing is linkable.

**Proposal.** Publish inventory output to **GitHub Pages**. The repo is public, so
Pages is available at no cost and needs no external service.

```
tenant-inventory run
  -> writes docs/data/<scope>-<timestamp>.json   (raw, kept N runs)
  -> writes docs/data/latest.json                (pointer)
  -> renders docs/index.html                     (static; reads the JSON client-side)
  -> deploys via actions/deploy-pages
```

Sequencing matters — build the cheap layers first, stop when it's enough:

| Layer | Effort | Value |
|---|---|---|
| 1. Markdown tables in `$GITHUB_STEP_SUMMARY` | ~1h | Huge. Readable inside the run, zero infra. |
| 2. Commit JSON snapshots to `docs/data/` | ~2h | History + diffability for free. |
| 3. Static HTML on Pages (sortable tables, counts) | ~1d | The actual "dashboard". |
| 4. Trend charts across snapshots | ~1d | Only worth it once several snapshots exist. |

**Do layer 1 first.** It captures most of the value and will reveal which views
people actually want before any HTML is written. Layer 4 is meaningless until
layer 2 has been running for weeks.

**Caution.** Inventory output includes integration configs and trusted IPs. On a
*public* repo that must not be published verbatim. Publish **counts, names, and
non-sensitive metadata**; keep raw payloads in the artifact (which respects repo
permissions). Decide this before layer 2, not after — git history is forever.

**Bigger idea, later:** a scheduled nightly inventory that opens a PR when the
snapshot changes turns the dashboard into **drift detection** — "someone added an
integration on Tuesday" becomes a reviewable diff rather than an archaeology
exercise. This is arguably worth more than the dashboard itself.

---

## 1. Improvements to existing workflows

Ordered by value/effort. The first three are small and remove real friction.

### High value, low effort

- **Step summaries everywhere.** All three workflows dump raw JSON into logs. A
  markdown table in `$GITHUB_STEP_SUMMARY` is a few lines of `jq` and is the single
  biggest readability win available. (Same work as dashboard layer 1.)

- **PR comment for compute-runtime dry run.** `rbac.yml` comments its plan on PRs;
  `compute-runtime-policies.yml` does not. A reviewer currently has to open the run
  and find the right step to see what a config change would do.

- **Concurrency `cancel-in-progress` for plan-only runs.** Currently `false`
  everywhere, which is correct for applies and wasteful for pushes.

### Medium

- **Drop `-target`.** Every run prints Terraform's "resource targeting is in effect"
  warning, which trains people to ignore warnings. `-target` is a break-glass flag
  being used as routine architecture. The real fix is a remote backend with separate
  state per area (see §3) — then each workflow plans only its own state and the flag
  disappears.

- **Cache provider plugins.** `terraform init` re-downloads on every run.
  `actions/cache` on `.terraform` cuts a meaningful chunk of wall-clock time.

- **Post-apply verification.** Applies report success from Terraform's perspective.
  For the script-driven compute path, "the API accepted the PUT" and "the rule now
  has the collection" are different claims. Re-read and assert after apply.

- **Rule-name autocomplete is impossible, so make listing lead into applying.**
  Attaching a collection requires an exact rule name copied out of a listing run.
  A workflow that outputs a ready-to-paste YAML block would remove the most common
  source of `rule_not_found`.

### Lower

- **Config schema validation.** A typo in `compute-runtime-policies.yaml` currently
  surfaces as a confusing Terraform type error. Validate the YAML shape early with a
  clear message.

- **`terraform fmt` is `continue-on-error: true`.** It reports and never blocks, so
  formatting drifts. Either enforce it or drop the step.

- **Dependabot** for the GitHub Actions and Terraform provider versions.

---

## 2. New workflows worth adding

The CSPM provider exposes **56 data sources**; we use 7. The gap below is mostly
"expose what already exists," not new integration work.

### Strong candidates

| Workflow | Why | Notes |
|---|---|---|
| **Cloud account inventory** (read) | `prismacloud_cloud_accounts` — which accounts are onboarded, their status. Probably the most-asked question in any tenant. | Pure read. Low risk. |
| **Policy & compliance inventory** (read) | `prismacloud_policies`, `prismacloud_compliance_standards` — what's enabled, what's custom vs default. | Pure read. Pairs naturally with the dashboard. |
| ~~**Team/role audit** (read)~~ | `prismacloud_user_roles`, `prismacloud_user_profiles`, `prismacloud_permission_groups` — who has what. | **DONE** — workflow 4, [`access-audit`](../terraform/modules/access-audit/README.md). |
| **Alerts snapshot** (read) | `prismacloud_alerts` — current open alerts by severity. | Best value as a *scheduled* run feeding trend charts. |

### Worth considering

- ~~**Drift detection** (scheduled)~~ — **DONE**, as workflow 5.

  The original framing here was wrong in an instructive way. It assumed a nightly
  `terraform plan` and therefore a remote backend (§3) as a prerequisite. With no
  prior state, every run looks like a first run, so that approach could never have
  worked as written.

  What shipped compares successive read-only **snapshots** instead. That needs no
  backend, and it covers strictly more: `terraform plan` only ever notices objects
  Terraform manages, whereas a snapshot notices a role someone created by hand in
  the console. Since most of this tenant is unmanaged, that difference is the
  greater part of the value.

  A backend is still worth having (§3), but it is now an *improvement* to drift
  detection rather than a blocker for it.
- **Onboard-a-team** — a `workflow_dispatch` form that writes a `teams.yaml` entry and
  opens a PR, instead of hand-editing YAML. Turns the repo into a self-service portal.
- **Compute collections management** — now that the Compute provider is wired in,
  managing collections directly is a small increment.

### Deliberately not recommended

- **Tenant settings *write* workflows** (enterprise settings, trusted IPs,
  integrations). These were built once and removed on purpose: tenant-wide blast
  radius, and they're rarely-changed settings where a console change with an audit
  trail is safer than a Terraform round-trip. Keep them read-only.

---

## 3. The structural item

Everything above is incremental. One thing is not:

**There is no remote backend.** State is local and ephemeral per job. Consequences:

- `-target` is required in every workflow to stop them fighting over one state file.
- Applies must re-plan rather than consume the uploaded plan artifact.
- No state locking, so two concurrent applies are unsafe.
- Terraform can't detect drift, because it has no prior state to compare against.
  (Worked around by snapshot comparison in workflow 5 — see §2 — but plan-based
  drift on *managed* resources still isn't possible.)

A backend (S3 + DynamoDB, or TFC) with **separate state per area** fixes all four at
once and removes the `-target` scaffolding.

This is a bigger change than anything else here and doesn't need to happen now — but
most of the awkwardness in the current setup traces back to it, so it's worth doing
before the workflow count grows much further.

---

## Suggested order

1. ~~Team/role audit (§2)~~ — **done**, workflow 4.
2. ~~Scheduled drift detection (§2)~~ — **done**, workflow 5. Moved to the front
   once it turned out not to depend on the remote backend.
3. Step summaries in the remaining workflows (§1) — biggest readability win per hour.
   Workflows 4 and 5 already do this.
4. PR comment for the compute dry run (§1).
5. Cloud account inventory workflow (§2) — proves the read-only pattern generalizes.
6. JSON snapshots to `docs/data/` (§0 layer 2). The sensitive-data policy is now
   settled by workflow 5: hash usernames at the source, and guard the output.
7. Pages dashboard (§0 layer 3) — the drift baseline is already a committed,
   machine-readable JSON document it could read directly.
8. Remote backend (§3), then drop `-target`.

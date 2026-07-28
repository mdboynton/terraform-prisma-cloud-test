# Compute Policies Module — Open Design Questions

These questions must be answered before implementing the `compute-policies` module.
They are all framed against the **reason the RBAC module exists**: to make onboarding a
team a *one-YAML-entry* operation that grants the team correct, scoped access. The
policies module should have an analogous justification — not merely "wrap 6 provider
resources," but *simplify a recurring, error-prone security-onboarding task*.

Key context grounding these questions:
- RBAC's unit of abstraction is the **team**, fanned out over
  [`config/teams.yaml`](../terraform/config/teams.yaml) with `for_each`
  ([`terraform/main.tf`](../terraform/main.tf:31)).
- Each team's Resource List (CAG) auto-spawns a **Collection**
  ([`modules/rbac/README.md`](../terraform/modules/rbac/README.md:62)).
- [`ARCHITECTURE_DIAGRAM.md`](../ARCHITECTURE_DIAGRAM.md:50) already envisions a
  *per-team CWP policy baseline* (Compliance / Vulnerability / Runtime) **scoped by the
  team's auto-spawned Collection**.
- **Core tension:** Compute Host/Container policies are **tenant-wide singletons** (one
  ordered rule list per policy type for the entire tenant), whereas RBAC's value comes
  from per-team fan-out. A *rule* inside a policy can be scoped to a Collection, but the
  *policy object* is global and its rule order is significant (first-match).

---

## A. Purpose & unit of abstraction (most fundamental)

1. What is the concrete onboarding pain this module removes? (e.g. "today, when a team
   is onboarded, someone manually adds Collection-scoped rules to the Runtime/Vuln/
   Compliance policies in the Compute console, and it's slow/inconsistent.") Describe
   the current manual process it replaces.

2. What is the module's unit of abstraction?
   - (a) **Per-team**, like RBAC — onboarding a team in `teams.yaml` also generates that
     team's policy rules, each scoped to the team's Collection; the module composes all
     teams' rules into the tenant-wide policy objects.
   - (b) **Tenant-wide baseline** — the module owns one standard org-wide policy baseline
     (not per-team); onboarding a team adds no rules.
   - (c) **Hybrid** — a tenant-wide default baseline PLUS optional per-team overrides,
     both Collection-scoped.

3. If per-team (2a/2c): should adding a team to `teams.yaml` *automatically* create its
   policy rules (zero extra config, like RBAC), or should policy rules be opt-in per
   team via a separate config block?

4. Does this module co-own the SAME tenant-wide policy objects that already exist in the
   tenant today? (i.e. must it **import** and manage the current live Runtime/Vuln/
   Compliance policies, preserving existing rules — see also Section E.)

---

## B. Collection dependency & cross-module coupling

5. Rules should be scoped to each team's **auto-spawned Collection**
   (`<resource-list> - Access Group (RBAC)`). The RBAC module currently resolves that
   Collection **by name** from the live tenant (not by a stable ID), and the auto-spawn
   has a 1-30s eventual-consistency window
   ([`modules/rbac/README.md`](../terraform/modules/rbac/README.md:134)). How should the
   policies module obtain the Collection reference?
   - (a) Consume the RBAC module's `resource_list_collection_ids` output (tight coupling,
     single apply, ordering via `depends_on`).
   - (b) Take Collection names/IDs as explicit inputs in config (loose coupling).
   - (c) The policies module creates/owns its own dedicated Collections instead of
     reusing the RBAC auto-Collections.

6. Should RBAC and policies be applied in the **same** root module/state (so a team is
   fully onboarded in one `terraform apply`), or in **separate** states/pipelines
   (RBAC first, policies second)?

7. If a team has **multiple** Resource Lists (RBAC supports 1..N), which Collection(s)
   should its policy rules target — all of them, or a designated primary?

---

## C. Policy behavior & safety

8. For each of the 6 policy types (Runtime/Vulnerability/Compliance × Host/Container),
   what is the desired **effect** for a newly onboarded team?
   - Alert-only vs. blocking/prevent?
   - The current diagram says "alert high + critical" — is that the intended default for
     all types, or per-type different?

9. Vulnerability policies use alert/block **thresholds** by severity (low/medium/high/
   critical) and can gate on grace periods, fixable-only, etc. What thresholds should
   the default per-team rule use?

10. Compliance policies reference specific **compliance checks/benchmarks** (e.g. CIS).
    Which benchmarks/check IDs should the default team rule include, or is it "all with
    severity ≥ high"?

11. Runtime policies have process/network/filesystem/dns sub-behaviors and
    learning/anomaly settings. What's the intended default posture (e.g. alert on
    anomalies, no blocking) for a new team?

12. **Rule ordering:** since policy rule order is significant (first-match), how should
    per-team rules be ordered relative to each other and to any existing catch-all/
    default rule at the bottom of each policy? (e.g. team rules inserted above the
    default deny/allow-all.)

13. Should there always be a **fallback/default rule** the module guarantees stays last,
    so removing all teams never leaves a policy empty/misconfigured?

---

## D. Config surface & authoring experience

14. Where should policy config live?
    - (a) Extend each team's block in `config/teams.yaml` (keeps "one team = one entry").
    - (b) A separate `config/compute-policies.yaml`.
    - (c) Both: team-level opt-in in `teams.yaml` + a shared defaults file.

15. How much per-team customization is needed vs. a fixed org standard? (Determines
    whether the YAML exposes full rule attributes or just a few knobs like
    `severity_threshold` and `mode: alert|block`.)

16. Should teams be able to **exclude** themselves from a policy type, or is the baseline
    mandatory for all onboarded teams?

---

## E. Ownership, migration & drift (tenant already has live policies)

17. The tenant already has Host/Container policies with existing rules (the diagram shows
    a live baseline). Will Terraform **take ownership** of these singleton policies? If
    so, we must import them and reproduce every current rule in config, or Terraform will
    delete rules it doesn't know about on first apply. Is a full inventory of current
    rules available to seed the config?

18. Who else edits these policies today (console admins, other automation)? If humans
    edit in-console after Terraform owns them, every apply will revert their changes —
    is that the desired guardrail, or do we need to tolerate out-of-band edits?

19. On the disposable test tenant: is it acceptable to create brand-new
    `tuan-test-*`-scoped rules for validation without importing the real baseline?

---

## F. Auth, provider & operational (lower-risk, mostly confirmable)

20. Compute Console auth: confirm the Compute Console URL
    (`https://us-east1.cloud.twistlock.com/us-2-158320372`) and which credential type to
    use — the same access-key/secret-key as CSPM, a dedicated Compute service account, or
    username/password? (The `prismacloudcompute` provider takes `console_url` +
    `username`/`password`.)

21. Provider version to pin for `PaloAltoNetworks/prismacloudcompute`? (I can resolve the
    latest published version locally via `terraform init` once unblocked.)

22. Same manual-dispatch-gated CI pipeline as RBAC, with added `TF_VAR_*` Compute
    secrets? Any separate approval owner for policy changes (they're
    tenant-wide/higher-blast-radius than per-team RBAC)?

---

## Recommendation (pending answers)
My current lean, to validate against your answers: **hybrid (2c)** — a module that owns
the tenant-wide policy objects with a small, reviewed **default baseline rule set**, and
optionally composes **per-team Collection-scoped rules** driven from `teams.yaml`, always
keeping a guaranteed-last fallback rule per policy. This preserves RBAC's "one team = one
entry" onboarding ergonomics while respecting the singleton, order-sensitive nature of
Compute policies. Sections A, B, and E are the blocking questions; C, D, F are tuning.

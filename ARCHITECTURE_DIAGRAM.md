## [`RBAC`](terraform/modules/rbac)

Manage RBAC objects (Roles, Account Groups, Resource Lists, Permission Groups, etc.) in Prisma Cloud.

```mermaid
flowchart LR
    subgraph Users
        U["user@example.com"]
    end

    subgraph ServiceAccounts["Service Accounts"]
        SA["&lt;team&gt;-service-account"]
        AK["Access Key<br/>(id + secret)"]
        SA --- AK
    end

    subgraph Roles
        R["&lt;team&gt;-role"]
    end

    subgraph PermissionGroups["Permission Groups"]
        PG["&lt;team&gt;-permission-group<br/>(shared)"]
        PG_MD["Manage Defenders"]
        PG_VR["View Radars"]
        PG_ETC["... (additional permissions)"]
        PG --> PG_MD
        PG --> PG_VR
        PG --> PG_ETC
    end

    subgraph AccountGroups["Account Groups (1..N)"]
        AG1["&lt;team&gt;-account-group-1"]
        AG2["&lt;team&gt;-account-group-2"]
        ACCT1["Account IDs"]
        ACCT2["Account IDs"]
        AG1 --> ACCT1
        AG2 --> ACCT2
    end

    subgraph ResourceLists["Resource Lists / CAG (1..N)"]
        RL1["&lt;team&gt;-resource-list-1"]
        RL2["&lt;team&gt;-resource-list-2"]
    end

    subgraph Collections
        C1["&lt;team&gt;-resource-list-1 - Access Group (RBAC)"]
        C2["&lt;team&gt;-resource-list-2 - Access Group (RBAC)"]
    end

    subgraph Policies["Policies (per-team CWP baseline: alert high + critical)"]
        subgraph Compliance
            CI["Containers and images"]
            CI_DEP["Deployed"]
            CI --> CI_DEP
        end
        subgraph Vulnerabilities
            IMG["Images"]
            IMG_DEP["Deployed"]
            IMG --> IMG_DEP
        end
        subgraph Runtime
            CON["Containers"]
        end
    end

    %% User / Service Account assigned to Role
    U -->|assigned| R
    SA -->|assigned| R

    %% Role references shared Permission Group
    R -->|references| PG

    %% Role binds multiple Account Groups
    R -->|binds| AG1
    R -->|binds| AG2

    %% Role binds multiple Resource Lists
    R -->|binds| RL1
    R -->|binds| RL2

    %% Each Resource List auto-spawns its own Collection
    RL1 -->|generates| C1
    RL2 -->|generates| C2

    %% Collections scope the per-team policies
    C1 -.->|scopes| CI_DEP
    C1 -.->|scopes| IMG_DEP
    C1 -.->|scopes| CON
```

## Flow

- Users and the Service Account are both assigned the team Role. The Service Account carries an Access Key (id + secret) for programmatic/CI access.
- The Role references the shared Permission Group and binds the team's Account Groups and Resource Lists (Compute Access Groups).
- Each Resource List auto-spawns a Collection named `<resource-list> - Access Group (RBAC)` on the Runtime Security side.
- Those Collections scope the per-team CWP policy baseline (Compliance, Vulnerabilities, Runtime), which alerts on high and critical findings.

## [`compute-runtime-policies`](terraform/modules/compute-runtime-policies)

Attaches an RBAC Collection to **existing** Compute **runtime** policy rules (Container +
Host) so console-authored policies apply to a team's resources. It does **not** create or
change policies — it only appends the collection to a matched rule, preserving the rest.
Because runtime policies are tenant-wide singletons, this is done via a non-destructive
**API read-merge-write** (mechanism B) rather than a Terraform provider resource.

```mermaid
flowchart LR
    RBAC["RBAC module"] --> COL["Collection<br/>&lt;team&gt;-assets"]
    YAML["config/compute-runtime-policies.yaml<br/>{ policy_rule_name, add_collection }"] --> M["compute-runtime-policies"]
    COL --> M

    subgraph ComputeConsole["Compute Console (Twistlock)"]
        CRP["Container runtime policy<br/>(singleton, ordered rules)"]
        HRP["Host runtime policy<br/>(singleton, ordered rules)"]
    end

    M -->|"GET → append collection → PUT (verbatim)"| CRP
    M -->|"GET → append collection → PUT (verbatim)"| HRP
    M -. "dry-run preview (every plan)" .-> PREVIEW["would_add /<br/>already_present /<br/>rule_not_found"]
```

### Flow

- The admin authors runtime policies in the Compute console (they own the policy content).
- The admin records, in `config/compute-runtime-policies.yaml`, which existing rule should
  cover which RBAC Collection, then commits + pushes — which triggers the GitHub Action.
- On `plan`, the module reads each live policy and previews per association whether the
  collection would be added, is already present, or the rule name wasn't found.
- On the gated `apply`, the module `GET`s the policy, appends the collection to the matched
  rule's `collections` (idempotent, preserving all existing collections and fields), and
  `PUT`s the exact object back — so only the targeted scoping changes.

## [`compute-alert-summary`](terraform/modules/compute-alert-summary)

Counts runtime incidents and image CVEs for one **Compute** collection. Read-only by
construction: `data` blocks only, so a plan has zero resource changes.

It is the **sibling** of [`alert-summary`](terraform/modules/alert-summary), which counts
**CSPM alerts** in a **CSPM Collection**. Prisma has two unrelated collection systems, and
these two modules read one each — the Compute `- Access Group (RBAC)` collections an RBAC
Resource List spawns do not exist on the CSPM side at all. **Their counts describe
different objects and must never be added together.**

```mermaid
flowchart LR
    RBAC["RBAC module"] -.->|"auto-spawns"| COL["Compute collection<br/>&lt;team&gt; - Access Group (RBAC)"]
    NAME["workflow input<br/>collection_name"] --> M["compute-alert-summary<br/>(data.external → summary.sh)"]
    COL -.->|"name, copied by hand"| NAME

    subgraph ComputeConsole["Compute Console (Twistlock)"]
        LIST["GET /api/v1/collections"]
        INC["GET /api/v1/audits/incidents<br/>?collections=&lt;name&gt;"]
        IMG["GET /api/v1/images<br/>?collections=&lt;name&gt; (100/page)"]
    end

    M -->|"1 · resolve name, else FAIL"| LIST
    M -->|"2 · count (+ unacked)"| INC
    M -->|"3 · page & reduce, sum CVEs"| IMG
    M --> OUT["status + counts<br/>ok / disabled / missing_credentials /<br/>tenant_wide_scope / partial_image_scan"]
```

### Flow

- The admin copies the collection name from the Compute console — Compute collections have
  **no id**, the name is the identifier, and the filter is exact-match and case-sensitive.
- The script resolves that name against the collection list **first** and fails with a
  suggestion on a case mismatch, rather than querying and returning a plausible wrong
  number. An empty name is refused: an absent filter returns the whole tenant.
- Incident and image counts come from server-side totals. The CVE severity rollup pages
  `/images` and reduces each page before fetching the next (~48 MB → ~14 KB), capped by
  `max_images`; when the cap is hit the run reports `partial_image_scan` and says the
  severity numbers are a sample.
- The workflow branches on the `status` output, never on the exit code: a failing `check`
  does not fail a plan, and `terraform show -json` omits check results from a plan file
  entirely.

## [`runtime-grace-digest`](terraform/modules/runtime-grace-digest)

Reports **which runtime rules are still firing**, grouped by rule + workload scope +
cloud account. Read-only by construction: `data` blocks only, so a plan has zero
resource changes.

It reads the **CSPM** alerts API, not the Compute Console. Runtime incidents are promoted
into the CSPM stream as `workload_incident` alerts, and the promoted copy carries the
runtime rule name (`metadata.auditRuleName`), an occurrence count, and the full dismissal
lifecycle — none of which the raw Compute incident offers on one call.

**It measures recurrence, not age.** A runtime incident is an event: it happened, nothing
un-happens it, and incidents never expire. "Older than N days" selects nearly everything
ever recorded (measured: 14,398 of 14,410) and only really tracks whether somebody clicked
acknowledge. "Still firing in the last N days" is answerable and self-clearing.

```mermaid
flowchart LR
    IN["workflow inputs<br/>window_days · alert_status · max_alerts"] --> M["runtime-grace-digest<br/>(data.external → digest.sh)"]
    SCHED["schedule<br/>Mon 08:00 UTC"] -.->|"defaults"| IN

    F["every query carries<br/>policy.type = workload_incident<br/>alert.status = alert_status<br/>detailed = true"] -.-> M

    subgraph CSPM["Prisma Cloud CSPM API"]
        direction TB
        ALL["POST /v2/alert · limit 1<br/>timeRange: to_now"]
        WIN["POST /v2/alert · limit 1<br/>timeRange: relative N days"]
        ROWS["POST /v2/alert · limit max_alerts<br/>timeRange: relative N days"]
    end

    M -->|"1 · all-time total"| ALL
    M -->|"2 · window total"| WIN
    M -->|"3 · fetch & reduce"| ROWS
    M --> G["group by<br/>rule + scope + account"]
    G --> OUT["status + rules[]<br/>ok / disabled / missing_credentials /<br/>suspect_unfiltered / partial_grouping"]

    G -.->|"opt-in: notify_enabled"| N["notify_plan.sh<br/>(data.external · no API calls)"]
    N --> NOUT["notify_status + warning_plan[]<br/>ok / disabled / no_override /<br/>all_overdue / has_unroutable"]
```

**The grace warning is planned, never sent.** With `notify_enabled` the module also
reports *who would be told* a rule is heading for escalation. It makes no further API
calls — it consumes the grouped table above — and it contains no SMTP client, webhook or
mail command. Every planned message is addressed to a required
`warning_recipient_override`; the owner addresses read from the alert travel alongside as
`would_notify`, for review only.

That is a required field rather than a dry-run boolean on purpose. A flag can be flipped
by accident; a required field that *replaces* the address means the unreviewed path does
not exist yet. Unlike every other module here, whose blast radius stops at a sandbox
tenant and is undone by another write, these are **live mailboxes of real people** and a
sent email cannot be recalled.

### Flow

- All three queries carry the same filters; only `timeRange` and `limit` differ.
  `detailed=true` is mandatory — without it `totalRows` is `0`, which reads as "no
  findings".
- Two count queries run **before** the detail fetch: an all-time baseline and the window.
  If a short window returns exactly the all-time count, the run reports
  `suspect_unfiltered` — the alerts API answers HTTP 200 and returns the **whole tenant**
  for a filter name it does not recognise, so equality is what a silently dropped filter
  looks like. The threshold is 90 days, because a long window legitimately covers
  everything.
- `scope` (container vs host) is derived from `policy.name`, **not** `metadata.auditType`
  — auditType is the audit kind (Filesystem/Network/Processes). The same rule name can
  exist in both the container and host policies, so scope is part of the grouping key;
  merging them would point a later escalation at the wrong policy.
- `limit` is a cap, not a page size: when it is hit the remainder is simply absent. The
  module compares the server-side window total against the rows actually fetched and
  reports `partial_grouping`, and the workflow prints that warning **above** the table
  with the affected figures tagged `(sampled)` — rules below the cut-off are missing
  entirely, not undercounted.
- Alerts attributed to `default` (the built-in learned model) are counted separately: there
  is no named rule to escalate, so presenting them as an actionable row would send someone
  looking for a rule that is not in the console.
- The workflow branches on `status`, never the exit code, on the same basis as its
  siblings. `disabled` and `missing_credentials` fail the run loudly rather than rendering
  an empty report, which would be a false all-clear.
- The countdown starts at the alert's own `alertTime` — the only timestamp that ages
  monotonically. **Not** `lastIncidentTime`: measured over 100 promoted alerts that
  *precedes* `alertTime` in 67 of them (median 343s — the incident fires and CSPM promotes
  it minutes later), so it is not even reliably the late end of the interval. **Not**
  `firstSeen` either: identical on 98 of 100, but earlier where it differs, which would
  escalate sooner.
- Only `open` alerts run the clock, and `open_first` is tracked separately from `first`.
  A rule whose old alerts were all dismissed plus one fresh open alert must not read as
  aged.
- Two conditions are reported rather than tolerated, because both would make a warning
  dishonest. **Everything already overdue:** the clock runs from the alert, so against an
  existing backlog the deadline passed long ago — sending that announces an expiry rather
  than giving notice, so a send path needs a campaign start date measured from first
  contact. **Unroutable groups:** alerts with no owner cannot be addressed to anyone, and
  are surfaced rather than dropped, because quietly skipping them is how a workload gets
  blocked with nobody warned.
- Only **counts** reach the job summary, which is readable by anyone with repo access; the
  addresses stay in the artifact, and `terraform/runtime-grace-digest.json` is git-ignored.

---

## [`runtime-rule-effects`](terraform/modules/runtime-rule-effects)

Reports **which firing rules are still only alerting**, and — behind a typed confirmation
and an environment approval — raises one of them to `prevent`/`block`. This is the only
module in the repository that changes enforcement on a live runtime security policy.

It needs **both** APIs. VERIFIED across 100 promoted alerts: the CSPM alert carries no
`effect` field at any depth. Enforcement state exists only inside the Compute Console
policy objects, so the question is answerable only by joining the two by rule name.

**An escalation targets an effect SITE, not a rule.** A container rule carries nine
independent effect sites and a host rule a smaller, different set, so there is no single
switch to flip. Every request is `(kind, rule, site, effect)` where `site` is a literal
jq path copied verbatim from the report.

```mermaid
flowchart LR
    IN["workflow inputs<br/>window_days · alert_status"] --> M["runtime-rule-effects<br/>(data.external → effects.sh)"]

    subgraph READ["read path — runs at PLAN"]
        direction TB
        CSPM["CSPM · POST /v2/alert<br/>policy.type = workload_incident"]
        CC["Compute · GET /policies/runtime/{container,host}"]
    end

    M --> CSPM
    M --> CC
    M --> J["join on rule name<br/>flatten to effect sites"]

    J --> A["alerting_sites<br/>THE CANDIDATES"]
    J --> E["enforced_sites<br/>already blocking, still firing"]
    J --> D["disabled_sites<br/>detection is OFF"]

    A -.->|"a human picks one"| REQ["escalations = [{kind, rule, site, effect}]<br/>+ apply_escalations = APPLY"]
    REQ --> NR["null_resource.escalate<br/>runs at APPLY only"]
    NR --> W["apply_escalation.sh<br/>GET → setpath → deep-diff → PUT"]
```

**`terraform plan` cannot write, structurally.** The escalation is a `null_resource`
provisioner, not a `data` source. That distinction is the whole design: a `data` source
executes during **plan**, so building it that way would mean the command every operator
treats as safe silently escalates live security policies. Verified on the live tenant —
with an escalation staged *and* confirmed, a plan reports one resource to create and
changes nothing.

### Flow

- Two independent conditions arm the write, and neither has a useful default. `escalations`
  must be non-empty and is **never derived** from `alerting_sites` — auto-deriving would
  mean widening the alert window silently escalates more rules. `apply_escalations` must be
  the exact word `APPLY`; verified that `""`, `true`, `yes` and `apply` all leave the module
  read-only.
- Credentials are passed through the provisioner `environment`, never `triggers`, because
  trigger values are stored verbatim in state. The trigger holds a sha256 of the requests
  only, so rotating a key does not re-trigger a policy write.
- **Validation precedes every network call.** An earlier version authenticated first, so a
  `block`-on-host request against an unreachable console reported "could not reach the
  Compute Console" and never mentioned the invalid request. The batch is also
  all-or-nothing: one bad entry rejects every entry, because a partially applied
  enforcement change is worse than none.
- `block` is container-only and `disable` is refused outright. `disable` is a fourth,
  undocumented effect value and the most common one in practice (611 of 805 container
  values measured); it means the detection is **off**, so `disable → prevent` switches on a
  detection that was never running — a far larger decision than `alert → prevent`.
- The writer re-derives from **current** state: GET the policy, `setpath` on the literal jq
  path, error if the rule is missing, ambiguous, or the site absent. It never replays a
  stale plan.
- Idempotency uses **deep JSON equality, not `cmp`**. The pre-image is the server's raw
  body and the post-image is jq's re-serialisation, which differ in whitespace even when
  nothing changed — a byte comparison reports "changed" every time, so the guard never
  fires and a re-run PUTs an identical document. (`compute-runtime-policies/scripts/
  merge_apply.sh` has the same latent bug, recorded and lower-impact.)
- The apply job re-validates **after** approval: approving an environment gate does not
  re-run a plan, so a preflight re-reads live state and refuses if the status is no longer
  `will_apply` or the target is no longer an alerting site — renamed, deleted, or already
  escalated by someone else.
- `-target=module.runtime_rule_effects` scopes the apply. Measured: without it a confirmed
  run planned 4 resource changes in the shared root state; with it, exactly 1. The plan job
  fails the run if anything outside the module would change.
- **Escalation never silences workflow 8.** Effect and logging are orthogonal — a blocked
  action still records an incident by design. A rule that keeps appearing in the digest
  after escalation is working, and reading that as failure is the most likely
  misinterpretation of this module's output.
- The built-in `default` model has no rule object and cannot be escalated at all. It is
  also, in some tenants, a real rule name, so an alert naming it cannot be assumed to come
  from the built-in model.

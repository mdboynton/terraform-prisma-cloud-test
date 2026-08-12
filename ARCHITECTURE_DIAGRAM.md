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

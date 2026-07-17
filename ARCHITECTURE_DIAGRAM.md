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

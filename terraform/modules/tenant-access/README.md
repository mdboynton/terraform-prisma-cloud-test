# tenant-access

Manages tenant-wide **network access controls**:

- **Trusted login IPs** (`prismacloud_trusted_login_ip`) — which source IPs may log in.
- **Login IP enforcement** (`prismacloud_trusted_login_ip_status`) — whether that allowlist is actually enforced.
- **Trusted alert IPs** (`prismacloud_trusted_alert_ip`) — ranges treated as internal for alerting.

All native provider resources — real plan diffs and drift detection, no scripts.

---

## ⚠️ Lockout warning — read before enabling enforcement

Setting `enforce_login_ip_allowlist = true` makes Prisma Cloud **reject every
login from an IP not covered by the allowlist, tenant-wide**. If the allowlist
is incomplete, **all users and all automation lose access to the tenant**, and
recovery requires Palo Alto support.

This is the highest blast-radius module in the repo. It is therefore:

1. **Isolated** in its own module, so an unrelated tenant-config change can
   never drag an enforcement flip along with it.
2. **Split**: defining the allowlist is a *separate, safe* action from enforcing
   it. You can land the CIDRs first, verify them, and enforce later.
3. **Interlocked**: turning enforcement on additionally requires
   `acknowledge_lockout_risk = true`. Two independent flags must agree.
4. **Guarded**: enforcement with an empty allowlist is rejected outright by a
   precondition.

Recommended rollout: land `trusted_login_ips` → confirm in the console that
every operator, CI runner and egress NAT address is covered → only then set
`enforce_login_ip_allowlist = true` together with `acknowledge_lockout_risk`.

---

## Scope and safety

| Property | Behaviour |
|---|---|
| Cardinality | Tenant-wide singletons/collections (not per team). |
| Default | **Disabled** (`enabled = false`). |
| Enforcement default | `null` — the enforcement toggle is left **unmanaged** unless you set it explicitly. |
| State addressing | Entries are keyed by `name`, so inserting/removing one does not churn the others. |

## Usage

Safe — defines the allowlist but enforces nothing:

```hcl
module "tenant_access" {
  source = "./modules/tenant-access"

  enabled = true

  trusted_login_ips = [
    {
      name        = "corp-egress"
      cidrs       = ["203.0.113.0/24", "198.51.100.10/32"]
      description = "Corporate egress NAT"
    },
    {
      name  = "ci-runners"
      cidrs = ["192.0.2.0/25"]
    },
  ]

  trusted_alert_ips = [
    {
      name = "internal-ranges"
      cidrs = [
        { cidr = "10.0.0.0/8", description = "RFC1918" },
      ]
    },
  ]
}
```

⚠️ Enforcing (only after verifying the list is complete):

```hcl
  enforce_login_ip_allowlist = true
  acknowledge_lockout_risk   = true   # required interlock
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `false` | Master switch. |
| `trusted_login_ips` | list(object) | `[]` | Allowlist entries: `{ name, cidrs, description }`. Safe on its own. |
| `enforce_login_ip_allowlist` | bool | `null` | ⚠️ Enforce the allowlist tenant-wide. `null` = leave unmanaged. |
| `acknowledge_lockout_risk` | bool | `false` | Interlock that must be `true` to enable enforcement. |
| `trusted_alert_ips` | list(object) | `[]` | Alert IP groups: `{ name, cidrs = [{ cidr, description }] }`. Does not affect login. |

All CIDRs are validated with `cidrnetmask()`, and entry names must be unique.

## Outputs

| Name | Description |
|---|---|
| `trusted_login_ip_ids` | Map of login IP entry name => Prisma Cloud ID. |
| `trusted_alert_ip_uuids` | Map of alert IP group name => UUID. |
| `trusted_alert_ip_cidr_counts` | Map of alert IP group name => CIDR count reported by the tenant. |
| `login_ip_enforcement_enabled` | Whether enforcement is managed and its value; null when unmanaged. |

## Notes & caveats

- Trusted **alert** IPs only affect alerting classification — they never affect
  authentication, so they carry no lockout risk.
- Because the enforcement toggle defaults to `null`, enabling this module to
  manage allowlist entries will not implicitly turn enforcement on or off.
- Apply is gated in CI: pushes only plan; the write requires a manual dispatch
  with approval. Do not bypass that for this module.

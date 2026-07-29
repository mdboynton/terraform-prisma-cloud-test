# tenant-settings

Manages the Prisma Cloud tenant's **enterprise settings** singleton — session
timeout, access-key validity, audit logging, default-policy behaviour and the
access-key expiry notification controls.

Unlike [`compute-runtime-policies`](../compute-runtime-policies), this module
uses the provider's **native** `prismacloud_enterprise_settings` resource and
data source. No scripts, no `curl`/`jq` — you get real plan diffs, drift
detection and state tracking for free.

## Scope and safety

| Property | Behaviour |
|---|---|
| Cardinality | **Singleton** — exactly one per tenant (not per team, unlike `rbac`). |
| Blast radius | Tenant-wide; affects every user. |
| Default | **Disabled** (`enabled = false`) — the module is inert until turned on. |
| Unset values | Every optional input defaults to `null`, meaning *"leave the tenant's current value alone"*. Only what you explicitly set is managed. |
| Destroy | `prevent_destroy` is set — this object is updated in place, never destroyed. |

## Adoption (important)

A live tenant **already has** an enterprise settings object, so a naive first
apply would try to create a duplicate. Adoption is handled by an `import` block
in the **root** module (`terraform/main.tf`), because Terraform only permits
`import` blocks at the root. The `adopt_existing` input documents that intent
for callers and gates the root-level import.

## Usage

```hcl
module "tenant_settings" {
  source = "./modules/tenant-settings"

  enabled = true

  # Required by the provider whenever the module is enabled.
  access_key_max_validity = 90

  # Only the settings you list are managed; everything else is left alone.
  session_timeout              = 60
  audit_logs_enabled           = true
  require_alert_dismissal_note = true
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `false` | Master switch. When false the module manages nothing. |
| `adopt_existing` | bool | `true` | Adopt the pre-existing singleton instead of creating one. |
| `access_key_max_validity` | number | `null` | **Required when enabled.** Max access-key validity in days. |
| `session_timeout` | number | `null` | Idle session timeout in minutes. |
| `alarm_enabled` | bool | `null` | Enable alarms tenant-wide. |
| `audit_logs_enabled` | bool | `null` | Enable audit logging. |
| `audit_log_siem_intgr_ids` | set(string) | `null` | SIEM integration IDs receiving audit logs. |
| `apply_default_policies_enabled` | bool | `null` | Apply the default policy set to new accounts. |
| `default_policies_enabled` | map(bool) | `null` | Which default policies are on, by severity. |
| `require_alert_dismissal_note` | bool | `null` | Require a note when dismissing alerts. |
| `user_attribution_in_notification` | bool | `null` | Include the attributed user in notifications. |
| `named_users_access_keys_expiry_notifications_enabled` | bool | `null` | Expiry notifications for named users. |
| `service_users_access_keys_expiry_notifications_enabled` | bool | `null` | Expiry notifications for service users. |
| `notification_threshold_access_keys_expiry` | number | `null` | Days before expiry to notify. |

## Outputs

| Name | Description |
|---|---|
| `enterprise_settings_id` | ID of the managed singleton. Null when disabled. |
| `current_enterprise_settings` | Read-only snapshot of the tenant's live settings, for auditing/diffing. Null when disabled. |

## Notes & caveats

- `access_key_max_validity` is **required by the provider**. A `precondition`
  fails fast with a clear message if the module is enabled without it.
- Because unset inputs are `null` rather than a hardcoded default, enabling this
  module will not silently rewrite settings you did not mention.
- Review the plan carefully on first apply: adoption means the diff is against
  whatever the tenant currently has, which may not match your expectations.

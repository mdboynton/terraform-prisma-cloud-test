# tenant-integrations

Manages tenant-level **outbound integrations** (`prismacloud_integration`) and
**reports** (`prismacloud_report`) using the provider's native resources.

## Scope

| Property | Behaviour |
|---|---|
| Cardinality | Tenant-level collections (not per team). |
| Default | **Disabled** (`enabled = false`). |
| State addressing | Keyed by `name`, so adding/removing an entry does not churn the rest. |
| Blast radius | Moderate — a broken integration stops alert delivery, but does not affect authentication or policy enforcement. |

## Not included yet

**Notification templates** (`prismacloud_notification_template`) are
deliberately out of scope for now: their `template_config` requires five nested
severity blocks (`basic_config`, `open`, `resolved`, `dismissed`, `snoozed`) and
warrants its own slice. Reports can still reference an **existing** template by
ID via `target.notification_template_id`.

## Handling secrets

`integrations[*].config` carries credentials (`api_key`, `password`,
`secret_key`, `private_key`, …). **Never commit these.** Supply them through
`TF_VAR_`/CI secrets and remember that anything applied is persisted in
Terraform state — treat the state file as a secret.

The `integrations` variable is intentionally **not** marked `sensitive` as a
whole: doing so would taint the derived `for_each` map, and Terraform forbids
sensitive values as `for_each` keys (the key would leak into resource
addresses). Integration *names* are not secrets; the credential fields are, and
they are protected by the provider and by sensitive root variables.

## Usage

```hcl
module "tenant_integrations" {
  source = "./modules/tenant-integrations"

  enabled = true

  integrations = [
    {
      name             = "secops-slack"
      integration_type = "slack"
      description      = "Alert delivery to #secops"
      config = {
        webhook_url = var.slack_webhook_url # sensitive, injected
      }
    },
    {
      name             = "splunk-siem"
      integration_type = "splunk"
      config = {
        url       = "https://splunk.example.com:8088"
        auth_token = var.splunk_token
      }
    },
  ]

  reports = [
    {
      name        = "monthly-compliance"
      report_type = "compliance"
      target = {
        account_groups   = ["prod-accounts"]
        notify_to        = ["secops@example.com"]
        schedule         = "0 0 1 * *"
        schedule_enabled = true
      }
    },
  ]
}
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `enabled` | bool | `false` | Master switch. |
| `integrations` | list(object) | `[]` | `{ name, integration_type, description, enabled, config }`. Only set the `config` fields your `integration_type` needs; the rest are omitted. |
| `reports` | list(object) | `[]` | `{ name, report_type, cloud_type, target }`. `target` controls scope and delivery. |

Names must be unique within each list. A report with
`target.schedule_enabled = true` must also define `target.schedule`.

## Outputs

| Name | Description |
|---|---|
| `integration_ids` | Map of integration name => Prisma Cloud integration ID. |
| `integration_status` | Map of name => `{ status, valid }` — useful for spotting integrations that were created but fail health checks. |
| `report_ids` | Map of report name => report ID. |
| `report_status` | Map of name => `{ status, next_schedule }`. |

## Notes & caveats

- The provider validates credentials asynchronously: an integration can apply
  successfully and still report `valid = false`. Check `integration_status`
  after apply rather than assuming success.
- `integration_config` is a required nested block in the provider schema, so it
  is always emitted exactly once per integration; unset fields pass through as
  `null` and are omitted from the API request.

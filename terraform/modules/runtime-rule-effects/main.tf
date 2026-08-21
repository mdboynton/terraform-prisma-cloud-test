locals {
  # A MISSING GITHUB SECRET ARRIVES AS AN EMPTY STRING, NOT NULL.
  #
  # `TF_VAR_x: ${{ secrets.ABSENT }}` sets the variable to "", so a null-only
  # check passes and the module proceeds to authenticate with empty credentials.
  # This exact bug shipped in two earlier modules and made their
  # `missing_credentials` status unreachable in CI - the one place it mattered.
  #
  # NOT coalesce(): it treats "" as absent and raises "Error in function call"
  # when every argument is empty, turning the guarded case into a hard plan
  # failure. `x != null && x != ""` is the safe form.
  creds_present = nonsensitive(
    var.cspm_url != null && var.cspm_url != "" &&
    var.compute_url != null && var.compute_url != "" &&
    var.access_key != null && var.access_key != "" &&
    var.secret_key != null && var.secret_key != ""
  )

  active = var.enabled && local.creds_present
}

# ----------------------------------------------------------------
# READ-ONLY BY CONSTRUCTION.
#
# A `data` block, not a `resource`, and the script it calls has no write route.
# A plan through this module reports zero resource changes, so it cannot alter
# the tenant even if someone runs apply.
# ----------------------------------------------------------------
data "external" "effects" {
  count = local.active ? 1 : 0

  program = ["bash", "${path.module}/scripts/effects.sh"]

  # Every value must be a string: the external data source protocol rejects
  # anything else, and a bare number fails the whole plan.
  query = {
    cspm_url     = var.cspm_url
    compute_url  = var.compute_url
    access_key   = var.access_key
    secret_key   = var.secret_key
    window_days  = tostring(var.window_days)
    alert_status = var.alert_status
    max_alerts   = tostring(var.max_alerts)
    skip_cert    = var.skip_cert_verification ? "true" : "false"
  }
}

locals {
  raw = local.active ? data.external.effects[0].result : null

  # Rehydrate. The script returns a flat string map because the protocol
  # demands one; the structure lives in `rules_json`.
  rules = local.raw == null ? [] : jsondecode(local.raw.rules_json)

  # Split by how confidently the alert was tied to a live rule. These are kept
  # apart rather than merged with a flag because the follow-on escalator must
  # never act on an ambiguous or unmatched row, and a flag is easy to ignore.
  matched_rules   = [for r in local.rules : r if r.match_status == "matched"]
  ambiguous_rules = [for r in local.rules : r if r.match_status == "ambiguous"]
  unmatched_rules = [for r in local.rules : r if r.match_status == "unmatched"]
  builtin_rules   = [for r in local.rules : r if r.match_status == "builtin"]

  # Flatten to one row per EFFECT SITE - the unit an escalation actually
  # targets. A rule has no single effect: a container rule carries 27
  # independent sites and a host rule 19, a different set.
  #
  # `site` is a literal jq path into the policy object, so the escalator can
  # address a change without re-deriving anything.
  sites = flatten([
    for r in local.matched_rules : [
      for m in r.matches : [
        for s in m.sites : {
          kind        = m.kind
          rule        = r.rule
          rule_index  = m.rule_index
          site        = s.site
          effect      = s.effect
          action      = s.action
          occurrences = r.occurrences
          alerts      = r.alerts
        }
      ]
    ]
  ])

  # -------------------------------------------------------------------------
  # Sites the API will actually accept an enforcing value for.
  #
  # ⚠️ MEASURED THE HARD WAY, run 32526631084. An operator escalated
  # host / pavila-runtime-test / network.denyListEffect from alert to prevent.
  # The rule was valid, the site was valid, it sat at `alert`, Terraform
  # planned the write and a human approved it. The API refused:
  #
  #   PUT /api/v1/policies/runtime/host -> HTTP 400
  #   {"err":"invalid network deny list effect runtime rule effect prevent"}
  #
  # Sitting at `alert` says nothing about whether a STRONGER value is allowed.
  # In the Console the host Networking rows render only Disable | Alert - there
  # is no Prevent button to press. The permitted set is a property of
  # (workload x site) and there is NO SCHEMA TO ASK: /openapi.json,
  # /api/v1/swagger.json, /api/v1/_docs and three other candidates all 404.
  # So the list below is transcribed from the Console UI, which is the only
  # authority that exists.
  #
  # ⚠️ DO NOT REPLACE THIS WITH A DATA-DRIVEN GUESS. The obvious inference -
  # "a site accepts prevent if some rule already holds prevent there" - is
  # wrong in BOTH directions on this very tenant:
  #   - container network.rawSocketsEffect HOLDS `block` on 2 rules, yet the
  #     UI offers it no Block button (false positive -> the 400 above)
  #   - host antiMalware.encryptedBinaries is `alert` on all 81 rules, yet the
  #     UI DOES offer Prevent (false negative -> a real target silently lost)
  # Usage is not permission. test_escalatable_sites.sh pins both cases.
  #
  # Host: the eight rows that show a Prevent button. Everything under host
  # `network.*` is alert-only. Container: everything EXCEPT Raw sockets.
  host_escalatable = [
    "antiMalware.cryptoMiner",
    "antiMalware.serviceUnknownOriginBinary",
    "antiMalware.userUnknownOriginBinary",
    "antiMalware.tempFSProc",
    "antiMalware.webShell",
    "antiMalware.deniedProcesses.effect",
    "dns.denyListEffect",
    "dns.intelligenceFeed",
  ]
  container_not_escalatable = ["network.rawSocketsEffect"]

  # customRules[N].effect is indexed, so it cannot be matched literally. It is
  # escalatable on both policies - the UI renders a full effect selector for a
  # custom rule - so the index is normalised away before comparing.
  #
  # ⚠️ TAGGED ONTO EACH SITE RATHER THAN KEYED IN A MAP. A map keyed on
  # kind|rule|site would blow up on a duplicate key, and rule names are NOT
  # unique - 3 names exist in both the container and host policies, and a
  # single policy may carry the same name twice. Carrying the flag on the row
  # cannot collide.
  tagged_sites = [
    for s in local.sites : merge(s, {
      escalatable = (
        startswith(s.site, "customRules[") ? true :
        s.kind == "host" ? contains(local.host_escalatable, s.site) :
        !contains(local.container_not_escalatable, s.site)
      )
    })
  ]

  # Sites that are merely alerting while the rule keeps firing: the candidates
  # a human would consider escalating.
  #
  # `disable` is deliberately EXCLUDED. VERIFIED: it is a fourth effect value,
  # undocumented in the pages consulted and the most common one in practice
  # (611 of 805 container values). It means the detection is OFF, so
  # disable -> prevent switches on a detection that was never running. That is a
  # different and much larger decision than alert -> prevent, and it is surfaced
  # separately rather than folded into a single "escalate me" list.
  alerting_sites = [
    for s in local.tagged_sites : s if s.effect == "alert" && s.escalatable
  ]

  # Alerting, but the API would refuse to enforce it. Reported separately so
  # the number does not silently shrink: these are real detections that simply
  # cannot be escalated, and hiding them entirely would misrepresent coverage.
  locked_sites = [
    for s in local.tagged_sites : s if s.effect == "alert" && !s.escalatable
  ]

  # ⚠️ THE STATE LISTS BELOW ARE NOT FILTERED. They report what IS, not what
  # may be changed. A site already at `prevent` is enforcing whether or not we
  # would offer to set it.
  disabled_sites = [for s in local.sites : s if s.effect == "disable"]

  # Already escalated, yet still producing alerts.
  #
  # This is the case workflow 8 CANNOT see, and the reason this module exists.
  # It is NOT a failure: escalating changes enforcement, not telemetry, so a
  # blocked action still records an incident by design. Anyone reading "still
  # firing" as "escalation did not work" is misreading it.
  enforced_sites = [for s in local.sites : s if contains(["prevent", "block"], s.effect)]
}

# ----------------------------------------------------------------
# Guards.
#
# `check` blocks warn without failing the plan - deliberately. A warning here
# means "read the output carefully", not "this run is invalid".
#
# ⚠️ A failing check does NOT fail the plan, AND `terraform show -json` omits
# the checks array from a plan file entirely. A caller cannot detect these
# programmatically at all. That is why `status` exists as an output.
# ----------------------------------------------------------------

check "rule_names_unambiguous" {
  assert {
    condition = local.raw == null ? true : length(local.ambiguous_rules) == 0
    error_message = format(
      "%d firing rule name(s) exist in BOTH the container and host policies, so which policy produced the alert is not knowable from alert data: %s. Their sites are reported per policy kind, but an escalation must name the policy explicitly.",
      length(local.ambiguous_rules),
      join(", ", [for r in local.ambiguous_rules : r.rule])
    )
  }
}

check "rules_still_exist" {
  assert {
    condition = local.raw == null ? true : length(local.unmatched_rules) == 0
    error_message = format(
      "%d firing rule name(s) do not match any live runtime rule: %s. Alerts outlive the rules that produced them, so there is nothing to escalate for these.",
      length(local.unmatched_rules),
      join(", ", [for r in local.unmatched_rules : r.rule])
    )
  }
}

# ----------------------------------------------------------------
# THE WRITE PATH - the only part of this module that changes the tenant.
#
# WHY null_resource AND NOT data.external:
#   A `data` source runs during PLAN. Using one here would mean `terraform
#   plan` - the command every operator treats as safe to run - silently
#   escalates live security policies. A `null_resource` provisioner runs
#   during APPLY only, so plan stays read-only and the change is reviewable
#   before it happens.
#
# TWO INDEPENDENT CONDITIONS must both hold before anything is written:
#   1. `apply_escalations` is exactly "APPLY" (checked here, and again in the
#      script, which refuses on its own).
#   2. `escalations` is non-empty and explicitly supplied by a human.
#
# CREDENTIALS ARE NOT IN `triggers`. Trigger values are stored verbatim in
# state; the access key and secret are passed through `environment` instead,
# which is not persisted. `escalations_digest` is a sha256 of the request
# list, so a changed request re-runs the write without state holding secrets.
# ----------------------------------------------------------------

locals {
  write_confirmed = var.apply_escalations == "APPLY"

  write_requested = (
    var.enabled
    && local.creds_present
    && local.write_confirmed
    && length(var.escalations) > 0
  )

  escalation_payload = jsonencode({
    compute_url            = var.compute_url
    access_key             = var.access_key
    secret_key             = var.secret_key
    confirm                = var.apply_escalations
    skip_cert_verification = var.skip_cert_verification
    requests               = var.escalations
  })

  # Digest of the REQUESTS only - deliberately excludes credentials so that
  # rotating a key does not re-trigger a policy write.
  escalations_digest = sha256(jsonencode(var.escalations))
}

resource "null_resource" "escalate" {
  count = local.write_requested ? 1 : 0

  triggers = {
    escalations = local.escalations_digest
    compute_url = var.compute_url
    script      = filesha256("${path.module}/scripts/apply_escalation.sh")
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "printf '%s' \"$PCC_PAYLOAD\" | ${path.module}/scripts/apply_escalation.sh"

    environment = {
      PCC_PAYLOAD = local.escalation_payload
    }
  }
}

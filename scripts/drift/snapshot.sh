#!/usr/bin/env bash
#
# snapshot.sh - reduce a Terraform plan JSON to a stable, privacy-safe
# fingerprint of the tenant's security-relevant configuration.
#
# WHY A SNAPSHOT INSTEAD OF `terraform plan` DRIFT DETECTION:
# this repo has no remote backend. State is local and thrown away when the job
# ends, so Terraform has no prior state to compare the tenant against and cannot
# report drift the usual way. Comparing successive read-only snapshots gives the
# same answer - "did something change since last time" - without requiring a
# backend, and it also covers objects Terraform does not manage at all.
#
# Usage: snapshot.sh <plan.json> <out.json>
#
# The output is designed to be committed to a PUBLIC repo, so it deliberately
# contains NO usernames, email addresses, IP addresses, or integration configs.
# Identity is carried as a salted-by-nothing SHA-256 prefix: stable across runs
# (so a diff is meaningful) but not reversible to an address by inspection.
#
# It is also ORDER-INDEPENDENT: every list is sorted by a stable key, because
# the API returns rows in arbitrary order and an unsorted snapshot would report
# drift on every run.

set -euo pipefail

fail() { echo "ERROR: $1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq is required but not found"

PLAN_JSON="${1:?usage: snapshot.sh <plan.json> <out.json>}"
OUT="${2:?usage: snapshot.sh <plan.json> <out.json>}"

[ -f "$PLAN_JSON" ] || fail "plan file not found: $PLAN_JSON"

# --slurpfile (not --argjson) so a large plan cannot overflow ARG_MAX.
# The plan MUST come from a run with access_audit_redact_usernames=true, so the
# usernames in it are already SHA-256 prefixes produced by the module. This
# script never hashes anything itself - jq has no cryptographic hash function,
# and the obvious substitute (@base64) is trivially reversible, which would be
# redaction in appearance only. Reusing the module's real hash keeps exactly one
# implementation of the guarantee. The email guard at the bottom enforces it.
jq -n --slurpfile plan "$PLAN_JSON" '
  ($plan[0].output_changes // {}) as $o
  | {
    # Counts are the cheapest and most robust drift signal: a change here is
    # unambiguous and needs no per-row comparison.
    counts: {
      roles:             ($o.access_audit_summary.after.roles.total // null),
      roles_unassigned:  ($o.access_audit_summary.after.roles.unassigned // null),
      users:             ($o.access_audit_summary.after.users.total // null),
      users_enabled:     ($o.access_audit_summary.after.users.enabled // null),
      users_disabled:    ($o.access_audit_summary.after.users.disabled // null),
      service_accounts:  ($o.access_audit_summary.after.users.service_accounts // null),
      permission_groups: ($o.access_audit_summary.after.permission_groups.total // null),
      integrations:      ($o.tenant_inventory_summary.after.integrations // null),
      reports:           ($o.tenant_inventory_summary.after.reports // null),
      trusted_login_ips: ($o.tenant_inventory_summary.after.trusted_login_ips // null),
      trusted_alert_ips: ($o.tenant_inventory_summary.after.trusted_alert_ips // null)
    },

    # Per-object detail, so a diff can say WHICH role changed rather than only
    # that the count moved. last_modified_ts is excluded on purpose: it changes
    # on unrelated edits and would produce noisy, unactionable diffs.
    roles: (
      ($o.access_audit_roles.after // [])
      | map({
          name:                .name,
          role_type:           .role_type,
          account_group_count: .account_group_count,
          assigned_user_count: .assigned_user_count
        })
      | sort_by(.name)
    ),

    permission_groups: (
      ($o.access_audit_permission_groups.after // [])
      | map({
          name:                  .name,
          permission_group_type: .permission_group_type,
          custom:                .custom,
          accept_account_groups: .accept_account_groups,
          accept_resource_lists: .accept_resource_lists
        })
      | sort_by(.name)
    ),

    # Users are reduced to the already-hashed id plus the two facts that matter
    # for access control: are they on, and how much can they reach. Deliberately
    # no display name and no last-login date (the latter changes constantly and
    # would make every snapshot differ).
    users: (
      ($o.access_audit_users.after // [])
      | map({
          id:           .username,
          account_type: .account_type,
          enabled:      .enabled,
          role_count:   .role_count
        })
      | sort_by(.id)
    )
  }
' > "$OUT" || fail "failed to build snapshot"

# Guard rather than trust: if a PII-shaped string ever reaches the snapshot, the
# run must fail LOUDLY rather than quietly commit it to a public repo.
#
# The offending file is DELETED, not just reported. Leaving it on disk would let
# a later step (or a retry that skips this script) commit the very data this
# check exists to stop.
if grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$OUT"; then
  rm -f "$OUT"
  fail "snapshot contained an email address - output deleted, refusing to emit.
       The plan was almost certainly produced WITHOUT
       access_audit_redact_usernames=true. Snapshots are committed to a public
       repo, so this is a hard failure rather than a warning."
fi

echo "Wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"

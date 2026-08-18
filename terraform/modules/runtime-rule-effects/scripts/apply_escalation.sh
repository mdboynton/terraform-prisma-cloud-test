#!/usr/bin/env bash
#
# apply_escalation.sh — THE ONLY FILE IN THIS MODULE THAT WRITES TO THE TENANT.
#
# Changes the enforcement effect at explicitly addressed sites on runtime policy
# rules: GET the live policy, set the requested effects, PUT the whole object
# back. Everything not addressed is preserved byte-for-byte.
#
# ---------------------------------------------------------------------------
# WHY THIS IS A SEPARATE FILE
# ---------------------------------------------------------------------------
# plan_escalation.sh has no PUT anywhere in it. Keeping the writer out of the
# planner means "show me what would change" cannot become "change it" through a
# flag mistake, a copy-paste, or a future edit to a shared code path. The two
# scripts share the request format and the address resolver, and nothing else.
#
# ---------------------------------------------------------------------------
# WHAT THIS REFUSES TO DO
# ---------------------------------------------------------------------------
#   * Run without PCC_CONFIRM=APPLY. Not a boolean: a bare `true` is too easy to
#     leave lying in an environment file.
#   * Apply a plan it did not just re-derive. The tenant is re-read and the
#     effects re-checked immediately before the PUT, so a policy edited by
#     someone else between plan and apply aborts instead of silently reverting
#     their change.
#   * Apply a partial batch. Any invalid request rejects everything.
#   * Set `disable`, or `block` on a host rule. Same refusals as the planner.
#   * PUT when nothing changed (deep JSON equality), so a re-run is a no-op.
#
# ---------------------------------------------------------------------------
# CONTRACT
# ---------------------------------------------------------------------------
# stdin : {"compute_url","access_key","secret_key","requests":[...],
#          "confirm","skip_cert_verification"}
#   each request: {"kind","rule","site","effect"}
# stdout: a JSON report of what was applied.
#
set -euo pipefail

fail() { echo "$*" >&2; exit 1; }

command -v jq   >/dev/null 2>&1 || fail "jq is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

INPUT="$(cat)"
[ -n "$INPUT" ] || fail "no input on stdin"

get() { jq -r --arg k "$1" '.[$k] // ""' <<<"$INPUT"; }

COMPUTE_URL="$(get compute_url)"
ACCESS_KEY="$(get access_key)"
SECRET_KEY="$(get secret_key)"
CONFIRM="$(get confirm)"
SKIP_CERT="$(get skip_cert_verification)"
REQUESTS="$(jq -c '.requests // []' <<<"$INPUT")"

# ---------------------------------------------------------------------------
# The confirmation gate.
#
# A specific word, not a boolean. `true` accumulates in env files and CI
# defaults; "APPLY" has to be typed deliberately for this one purpose.
# ---------------------------------------------------------------------------
[ "$CONFIRM" = "APPLY" ] || fail \
  "refusing to write: confirm must be exactly \"APPLY\" (got \"${CONFIRM:-<empty>}\").
 This script changes enforcement on live runtime security policies. Run
 plan_escalation.sh first and read the diff."

[ -n "$COMPUTE_URL" ] || fail "compute_url is required"
[ -n "$ACCESS_KEY" ]  || fail "access_key is required"
[ -n "$SECRET_KEY" ]  || fail "secret_key is required"

REQ_COUNT="$(jq -r 'length' <<<"$REQUESTS")"
[ "$REQ_COUNT" -gt 0 ] || fail "requests is empty - nothing to apply"

COMPUTE_BASE="${COMPUTE_URL%/}"

CURL_OPTS=(--silent --show-error --max-time 120)
[ "$SKIP_CERT" = "true" ] && CURL_OPTS+=(--insecure)

# ---------------------------------------------------------------------------
# Validate the whole batch BEFORE any network call.
#
# ORDER MATTERS, and an earlier version of this script got it wrong: it
# authenticated first, so a batch containing an invalid request against an
# unreachable console reported "could not reach the Compute Console" and never
# mentioned the invalid request at all. The operator would fix the URL, re-run,
# and only then discover the batch was malformed. Refusals are cheap and
# certain; check them first.
#
# All-or-nothing: a half-applied escalation leaves the tenant in a state nobody
# planned and nobody reviewed.
# ---------------------------------------------------------------------------
VALID_EFFECTS='["alert","prevent","block","allow"]'

# One filter, defined once, used for both the count and the report - so the
# thing that is counted is exactly the thing that gets listed.
cat > "$TMP/invalid.jq" <<'JQEOF'
.[] | select(
    ((.kind // "") | IN("container","host") | not)
    or ((.rule   | type) != "string") or ((.rule   // "") == "")
    or ((.site   | type) != "string") or ((.site   // "") == "")
    or ((.effect | type) != "string")
    or (((.effect // "") | IN($valid[])) | not)
    or ((.kind // "") == "host" and (.effect // "") == "block")
)
JQEOF

BAD="$(jq -r --argjson valid "$VALID_EFFECTS" -f "$TMP/invalid.jq" <<<"$REQUESTS" | jq -s 'length')"

if [ "$BAD" -gt 0 ]; then
  jq -r --argjson valid "$VALID_EFFECTS" \
    "$(cat "$TMP/invalid.jq")"' | "  rejected: kind=\(.kind // "?") rule=\(.rule // "?") site=\(.site // "?") effect=\(.effect // "?")"' \
    <<<"$REQUESTS" >&2
  fail "$BAD of $REQ_COUNT requests are invalid - NOTHING was applied and no
 connection was made. Effect must be one of alert|prevent|block|allow.
 'disable' is refused: it is an undocumented value that turns a control OFF,
 which is the opposite of an escalation. 'block' is refused on host rules: the
 host policy has no such effect."
fi

# ---------------------------------------------------------------------------
# Authenticate. Status captured separately: --fail-with-body under `set -e`
# kills the pipeline before the error can be interpreted, which surfaces an
# expired key as a bare "curl: (22)".
# ---------------------------------------------------------------------------
code="$(jq -nc --arg u "$ACCESS_KEY" --arg p "$SECRET_KEY" '{username:$u,password:$p}' \
  | curl "${CURL_OPTS[@]}" -X POST "$COMPUTE_BASE/api/v1/authenticate" \
      -H 'Content-Type: application/json' --data @- \
      -o "$TMP/auth.json" -w '%{http_code}')" \
  || fail "could not reach the Compute Console at $COMPUTE_BASE"

case "$code" in
  200|201) ;;
  401|403) fail "Compute authentication was rejected (HTTP $code) - check the access key and secret." ;;
  404)     fail "Compute authentication got HTTP 404 at $COMPUTE_BASE/api/v1/authenticate - the console URL must INCLUDE its path prefix." ;;
  *)       fail "Compute authentication failed with HTTP $code" ;;
esac

TOKEN="$(jq -r '.token // ""' "$TMP/auth.json")"
[ -n "$TOKEN" ] || fail "Compute authentication succeeded but returned an EMPTY token"
printf 'Authorization: Bearer %s' "$TOKEN" > "$TMP/auth.hdr"
chmod 600 "$TMP/auth.hdr"

# ---------------------------------------------------------------------------
# Address resolution, shared with the planner.
#
# `site` is a literal jq path into the rule. Anything not addressed is left
# exactly as the API returned it - the PUT body is the GET body with only the
# named leaves changed.
# ---------------------------------------------------------------------------
cat > "$TMP/apply.jq" <<'JQEOF'
def to_path($site):
  $site | split(".")
  | map( if test("^(.+)\\[([0-9]+)\\]$")
         then ( capture("^(?<n>.+)\\[(?<i>[0-9]+)\\]$") | [.n, (.i | tonumber)] )
         else [.] end )
  | add;

# $policy is the live document; $reqs are the requests for THIS kind.
reduce $reqs[] as $r ($policy;
  . as $doc
  | ( [ $doc.rules // [] | to_entries[] | select(.value.name == $r.rule) ] ) as $hits
  | if ($hits | length) == 0 then
      error("rule not found in the live policy: \($r.rule) (\($r.kind)). It may have been renamed or deleted since the plan was generated.")
    elif ($hits | length) > 1 then
      error("rule name is ambiguous in the live policy: \($r.rule) (\($r.kind)) matches \($hits|length) rules.")
    else
      ($hits[0].key) as $idx
      | (["rules", $idx] + to_path($r.site)) as $p
      | if ($doc | getpath($p)) == null then
          error("effect site does not exist on \($r.rule) (\($r.kind)): \($r.site). The rule shape differs from the plan.")
        else
          $doc | setpath($p; $r.effect)
        end
    end
)
JQEOF

# ---------------------------------------------------------------------------
# Apply, one policy kind at a time.
# ---------------------------------------------------------------------------
RESULTS="[]"

for KIND in container host; do
  KIND_REQS="$(jq -c --arg k "$KIND" '[ .[] | select(.kind == $k) ]' <<<"$REQUESTS")"
  [ "$(jq -r 'length' <<<"$KIND_REQS")" -gt 0 ] || continue

  PATH_SUFFIX="/api/v1/policies/runtime/$KIND"

  # GET the live policy verbatim. This is the pre-image for the diff AND the
  # base for the PUT body, so every untouched field survives the round trip.
  code="$(curl "${CURL_OPTS[@]}" -H @"$TMP/auth.hdr" \
      -X GET "$COMPUTE_BASE$PATH_SUFFIX" \
      -o "$TMP/$KIND.before.json" -w '%{http_code}')" \
    || fail "failed to read the $KIND runtime policy"
  [ "$code" = "200" ] || fail "GET $PATH_SUFFIX returned HTTP $code - nothing was applied"

  jq -e 'type == "object"' "$TMP/$KIND.before.json" >/dev/null 2>&1 \
    || fail "the $KIND runtime policy did not come back as a JSON object"

  # Re-derive the change from CURRENT state. If someone edited this policy
  # since the plan was produced, the merge fails here rather than silently
  # overwriting their work.
  jq --slurpfile p "$TMP/$KIND.before.json" --argjson reqs "$KIND_REQS" \
     -n '$p[0] as $policy | '"$(cat "$TMP/apply.jq")" \
     > "$TMP/$KIND.after.json" 2>"$TMP/$KIND.err" \
    || fail "could not apply the $KIND changes to the live policy - NOTHING was written.
$(sed 's/^/  /' "$TMP/$KIND.err")"

  # Idempotency: no PUT when the document is unchanged.
  #
  # This deliberately does NOT use `cmp`. The "before" file is the server's
  # response verbatim; the "after" file is jq's re-serialisation of it. Those
  # two differ in whitespace and key order even when nothing was modified, so
  # a byte comparison reports "changed" every single time and the guard never
  # fires -- meaning a re-run would PUT an identical document back to the
  # tenant. jq's `==` is a deep value comparison: key order is ignored, array
  # order (which is meaningful for rules) is not.
  if jq -e -n --slurpfile b "$TMP/$KIND.before.json" \
              --slurpfile a "$TMP/$KIND.after.json" \
              '$b[0] == $a[0]' >/dev/null; then
    RESULTS="$(jq -c --arg k "$KIND" --argjson n "$(jq -r 'length' <<<"$KIND_REQS")" \
      '. + [{kind:$k, requested:$n, changed:false, http:null,
             note:"already at the requested effects - no write was made"}]' <<<"$RESULTS")"
    continue
  fi

  # PUT from a FILE: a large policy exceeds ARG_MAX on -d.
  code="$(curl "${CURL_OPTS[@]}" -H @"$TMP/auth.hdr" \
      -H 'Content-Type: application/json' \
      -X PUT "$COMPUTE_BASE$PATH_SUFFIX" \
      --data-binary @"$TMP/$KIND.after.json" \
      -o "$TMP/$KIND.put.json" -w '%{http_code}')" \
    || fail "the PUT to $PATH_SUFFIX could not be completed - the $KIND policy may be partially updated, re-run the reporter to check"

  case "$code" in
    200|201|204) ;;
    *)
      # The response body carries the reason; without it a 400 is unreadable.
      fail "PUT $PATH_SUFFIX returned HTTP $code - the $KIND policy was NOT updated.
 Response: $(head -c 2000 "$TMP/$KIND.put.json" 2>/dev/null || echo '<empty>')" ;;
  esac

  RESULTS="$(jq -c --arg k "$KIND" --arg c "$code" \
    --argjson n "$(jq -r 'length' <<<"$KIND_REQS")" \
    '. + [{kind:$k, requested:$n, changed:true, http:$c, note:"applied"}]' <<<"$RESULTS")"
done

jq -nc \
  --arg confirmed  "true" \
  --arg requested  "$REQ_COUNT" \
  --arg applied    "$(jq -r '[.[] | select(.changed)] | length' <<<"$RESULTS")" \
  --arg unchanged  "$(jq -r '[.[] | select(.changed | not)] | length' <<<"$RESULTS")" \
  --arg results_json "$RESULTS" \
  '$ARGS.named'

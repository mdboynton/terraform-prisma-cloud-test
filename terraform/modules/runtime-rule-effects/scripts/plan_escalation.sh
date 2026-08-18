#!/usr/bin/env bash
#
# plan_escalation.sh — validate requested effect changes and emit a DIFF.
#
# READ-ONLY. One GET per referenced policy kind and nothing else. There is no
# PUT in this file. The writer is a separate script, so "generate a plan" cannot
# become "apply a change" through a flag mistake or a copy-paste error.
#
# ---------------------------------------------------------------------------
# AN ESCALATION IS ADDRESSED, NEVER INFERRED
#
# Each request names all four coordinates:
#
#   kind    container | host          - which runtime policy
#   rule    exact rule name           - must resolve to exactly one rule
#   site    e.g. processes.deniedList.effect
#                 advancedProtectionEffect
#                 customRules[0].effect
#   effect  alert | prevent | block | allow
#
# The site is required because VERIFIED: a rule has no single effect. A
# container rule carries nine independent effect sites and a host rule a
# different, smaller set. Deriving the site from the alert's auditType would be
# a guess (Filesystem could mean filesystem.deniedList OR antiMalware), and a
# wrong guess changes an unrelated control on a live security policy.
#
# ---------------------------------------------------------------------------
# WHAT THIS REFUSES TO DO
#
# Any invalid request fails the WHOLE batch rather than skipping one entry. A
# partially-applied escalation set is worse than none: the operator believes all
# of it landed.
#
#   - rule not found                 - nothing to change
#   - site absent on that rule       - the address is wrong
#   - site is not a string field     - the address points at a section
#   - effect already at target       - reported as a no-op, not an error
#   - `block` on a host policy       - VERIFIED absent from host: 0 of 133 host
#     effect values are `block` (alert=106, prevent=21, allow=6)
#   - `disable`                      - refused: that turns the detection OFF,
#     which a workflow named "escalate" must never do silently
#
# A rule name existing in BOTH policies is NOT an error here: the request names
# the kind, which is exactly the disambiguation the alert could not provide.
#
# ---------------------------------------------------------------------------
# Input (stdin, JSON):
#   {"compute_url","access_key","secret_key","skip_cert",
#    "requests":[{"kind","rule","site","effect"}, ...]}
#
# Output (stdout): JSON {ok, changes[], noops[], errors[]}

set -euo pipefail

fail() { echo "Error Message: $1" >&2; exit 1; }

command -v jq   >/dev/null 2>&1 || fail "jq is required but not found"
command -v curl >/dev/null 2>&1 || fail "curl is required but not found"

INPUT="$(cat)"
[ -n "$INPUT" ] || fail "no input received on stdin"
jq -e . >/dev/null 2>&1 <<<"$INPUT" || fail "input is not valid JSON"

g() { jq -r --arg k "$1" '.[$k] // ""' <<<"$INPUT"; }

COMPUTE_URL="$(g compute_url)"
ACCESS_KEY="$(g access_key)"
SECRET_KEY="$(g secret_key)"
SKIP_CERT="$(g skip_cert)"
REQUESTS="$(jq -c '.requests // []' <<<"$INPUT")"

[ -n "$COMPUTE_URL" ] || fail "compute_url is required"
[ -n "$ACCESS_KEY" ]  || fail "access_key is required"
[ -n "$SECRET_KEY" ]  || fail "secret_key is required"

REQ_COUNT="$(jq -r 'length' <<<"$REQUESTS")"
[ "$REQ_COUNT" -gt 0 ] || fail "requests is empty - nothing to plan"

COMPUTE_BASE="${COMPUTE_URL%/}"

CURL_OPTS=(--silent --show-error --max-time 120)
[ "$SKIP_CERT" = "true" ] && CURL_OPTS+=(-k)

TMP="$(mktemp -d)"
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

# ---------------------------------------------------------------------------
# Auth. The status code is inspected explicitly: with --fail-with-body under
# `set -e`, a 401 kills the pipeline before any diagnosis runs and the operator
# sees a bare `curl: (22)` instead of a sentence naming the problem.
# ---------------------------------------------------------------------------
CODE="$(jq -nc --arg u "$ACCESS_KEY" --arg p "$SECRET_KEY" '{username:$u,password:$p}' \
  | curl "${CURL_OPTS[@]}" -H 'Content-Type: application/json' \
      -X POST "$COMPUTE_BASE/api/v1/authenticate" --data @- \
      -o "$TMP/auth.json" -w '%{http_code}')" \
  || fail "could not reach the Compute console at $COMPUTE_BASE"

case "$CODE" in
  200 | 201) ;;
  401 | 403) fail "Compute authentication was rejected (HTTP $CODE) - wrong access key or secret, or insufficient permission" ;;
  404) fail "Compute authentication got HTTP 404 - the console URL must INCLUDE its path prefix, e.g. https://<region>.cloud.twistlock.com/<tenant-id>" ;;
  *) fail "Compute authentication returned HTTP $CODE" ;;
esac

jq -r '"Authorization: Bearer " + (.token // "")' "$TMP/auth.json" > "$TMP/cc.hdr"
chmod 600 "$TMP/cc.hdr"
grep -q 'Bearer .\+' "$TMP/cc.hdr" \
  || fail "Compute authentication returned an EMPTY token - the console URL is probably missing its path prefix"

# ---------------------------------------------------------------------------
# Fetch only the policies actually referenced. Both files are created either
# way so the jq program can slurp them unconditionally.
# ---------------------------------------------------------------------------
echo 'null' > "$TMP/container.json"
echo 'null' > "$TMP/host.json"

for kind in $(jq -r '[.[].kind // empty] | unique | .[]' <<<"$REQUESTS"); do
  case "$kind" in
    container | host) ;;
    *) fail "kind must be 'container' or 'host', got '$kind'" ;;
  esac
  curl "${CURL_OPTS[@]}" --fail-with-body -H @"$TMP/cc.hdr" \
    -X GET "$COMPUTE_BASE/api/v1/policies/runtime/$kind" > "$TMP/$kind.json" \
    || fail "failed to read the $kind runtime policy"
done

# ---------------------------------------------------------------------------
# Validate each request and build the diff.
#
# The jq program lives in a FILE passed with -f, not inline. An inline
# single-quoted jq program cannot contain a single quote, and the error messages
# below need them ("no rule named 'x'"). Working around that with nested
# escaping is precisely where shell quoting bugs breed - and did, in the first
# version of this script. A file removes the shell's parser from the equation.
#
# `site` is converted to a jq path so one address form works for a nested
# section (processes.deniedList.effect), a rule-level key
# (advancedProtectionEffect) and an indexed custom rule (customRules[0].effect).
# ---------------------------------------------------------------------------
cat > "$TMP/plan.jq" <<'JQEOF'
def policy($kind):
  if $kind == "container" then $container[0] else $host[0] end;

# "customRules[0].effect" -> ["customRules", 0, "effect"]
def to_path($site):
  $site | split(".")
  | map( if test("^(.+)\\[([0-9]+)\\]$")
         then ( capture("^(?<n>.+)\\[(?<i>[0-9]+)\\]$") | [.n, (.i | tonumber)] )
         else [.] end )
  | add;

["alert", "prevent", "block", "allow"] as $valid

| reduce $requests[] as $r ({changes: [], noops: [], errors: []};
    . as $acc
    | ($r.kind // "")   as $kind
    | ($r.rule // "")   as $rule
    | ($r.site // "")   as $site
    | ($r.effect // "") as $want
    | (policy($kind))   as $pol

    | if ($kind | IN("container", "host") | not) then
        $acc | .errors += [{request: $r, error: "kind must be container or host"}]

      elif $rule == "" or $site == "" then
        $acc | .errors += [{request: $r, error: "rule and site are both required"}]

      elif $want == "disable" then
        $acc | .errors += [{request: $r, error: "refusing to set effect=disable: that DISABLES the detection. An escalation must not reduce coverage."}]

      elif ($want | IN($valid[]) | not) then
        $acc | .errors += [{request: $r, error: "effect must be one of alert|prevent|block|allow, got '\($want)'"}]

      elif ($kind == "host" and $want == "block") then
        $acc | .errors += [{request: $r, error: "host runtime policies do not support effect=block - use prevent"}]

      elif $pol == null then
        $acc | .errors += [{request: $r, error: "the \($kind) policy was not fetched"}]

      else
        ([$pol.rules // [] | to_entries[] | select(.value.name == $rule)]) as $hits
        | if ($hits | length) == 0 then
            $acc | .errors += [{request: $r, error: "no rule named '\($rule)' in the \($kind) policy"}]
          elif ($hits | length) > 1 then
            $acc | .errors += [{request: $r, error: "\($hits | length) rules named '\($rule)' in the \($kind) policy - cannot address one unambiguously"}]
          else
            ($hits[0].key)   as $ri
            | ($hits[0].value) as $rv
            | (to_path($site)) as $p
            | ($rv | getpath($p)) as $current
            | if $current == null then
                $acc | .errors += [{request: $r, error: "site '\($site)' does not exist on rule '\($rule)' in the \($kind) policy"}]
              elif ($current | type) != "string" then
                $acc | .errors += [{request: $r, error: "site '\($site)' is not an effect field (found \($current | type))"}]
              elif $current == $want then
                $acc | .noops += [{kind: $kind, rule: $rule, rule_index: $ri, site: $site, effect: $current, note: "already \($want)"}]
              else
                $acc | .changes += [{kind: $kind, rule: $rule, rule_index: $ri, site: $site, path: $p, from: $current, to: $want}]
              end
          end
      end
  )
| . + {ok: ((.errors | length) == 0)}
JQEOF

RESULT="$(jq -n \
  --argjson requests "$REQUESTS" \
  --slurpfile container "$TMP/container.json" \
  --slurpfile host "$TMP/host.json" \
  -f "$TMP/plan.jq")" \
  || fail "failed to evaluate the requested changes"

# A batch with any error produces NO changes at all.
if [ "$(jq -r '.ok' <<<"$RESULT")" != "true" ]; then
  {
    echo "Error Message: $(jq -r '.errors | length' <<<"$RESULT") of $REQ_COUNT requested change(s) are invalid - NOTHING was planned."
    jq -r '.errors[] | "  - [\(.request.kind // "?")] \(.request.rule // "?") @ \(.request.site // "(no site)"): \(.error)"' <<<"$RESULT"
  } >&2
  exit 1
fi

printf '%s\n' "$RESULT"

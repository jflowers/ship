#!/usr/bin/env bash
# Runs deps-automerge.yml's decide and gate steps (read out with yq, so the
# workflow stays the only copy) and settings-sync.sh, against a fake gh
# that answers `gh api <path> --jq <expr>` from fixture JSON and logs
# writes.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
wf=$here/../.github/workflows/deps-automerge.yml
decide=$(yq '.jobs.automerge.steps[] | select(.id == "decide") | .run' "$wf")
gate=$(yq '.jobs.automerge.steps[] | select(.id == "gate") | .run' "$wf")
[ -n "$decide" ] && [ -n "$gate" ] || { echo "no decide/gate step in $wf"; exit 1; }

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/api"
fails=0
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; sed 's/^/     /' "$t/out"; fails=$((fails + 1)); }

cat >"$t/bin/gh" <<'EOF'
#!/usr/bin/env bash
# gh api [-X METHOD] [-F k=v]... [--input -] <path> [--jq expr]
[ "$1" = api ] || { echo "fake gh: $*" >&2; exit 1; }
shift
method=GET path="" jq_expr="." fields=() input=0
while (($#)); do
  case $1 in
    -X) method=$2; shift ;;
    -F) fields+=("$2"); shift ;;
    --input) input=1; shift ;;
    --jq) jq_expr=$2; shift ;;
    --silent) jq_expr=empty ;;
    *) path=$1 ;;
  esac
  shift
done
if [ "$method" != GET ]; then
  { echo "$method $path ${fields[*]}"; [ "$input" = 0 ] || cat; } >>"$FAKE_API/calls"
  exit 0
fi
f=$FAKE_API/$(echo "$path" | tr / _).json
[ -f "$f" ] || { echo "HTTP 404: $path" >&2; exit 1; }
jq -r "$jq_expr" "$f"
EOF
chmod +x "$t/bin/gh"
export PATH=$t/bin:$PATH FAKE_API=$t/api

api() { cat >"$t/api/$(echo "$1" | tr / _).json"; }

# --- decide -----------------------------------------------------------------
decide() { # <update-type> <max> <deps json> -> prints "safe owned"
  : >"$t/o"
  UPDATE_TYPE=$1 MAX=$2 DEPS_JSON=$3 OWNERS="jflowers unbound-force" GITHUB_OUTPUT=$t/o \
    bash -c "$decide" >"$t/out" 2>&1 || return 1
  echo "$(sed -n 's/^safe=//p' "$t/o") $(sed -n 's/^owned=//p' "$t/o")"
}
dep() { jq -cn '[$ARGS.positional[] | {dependencyName: .}]' --args "$@"; }
check_decide() { # <type> <max> <deps json> <want "safe owned"> <label>
  if [ "$(decide "$1" "$2" "$3")" = "$4" ]; then ok "decide: $5"; else fail "decide: $5"; fi
}
P=version-update:semver-patch M=version-update:semver-minor J=version-update:semver-major
check_decide $P minor "$(dep jflowers/ship)" "true true" "own action patch merges"
check_decide $M minor "$(dep jflowers/ship/.github/workflows/go-release.yml)" "true true" "own reusable workflow"
check_decide $M minor "$(dep github.com/unbound-force/gaze)" "true true" "own Go module"
check_decide $P minor "$(dep @jflowers/pkg)" "true true" "own scoped npm package"
check_decide $P minor "$(dep actions/checkout)" "true false" "third-party is safe, not owned"
check_decide $P minor "$(dep jflowers/ship golang.org/x/net)" "true false" "a group with one third-party isn't owned"
check_decide $P minor "$(dep github.com/jflowersx/y)" "true false" "owner must match exactly"
check_decide $J minor "$(dep jflowers/ship)" "false true" "own major waits"
check_decide $M patch "$(dep jflowers/ship)" "false true" "minor above patch waits"
check_decide $J major "$(dep jflowers/ship)" "true true" "major within major"
check_decide "" minor "$(dep jflowers/ship)" "false true" "unknown type waits"
check_decide $P minor "[]" "true false" "no dependencies isn't owned"
if decide $P sometimes "$(dep jflowers/ship)" >/dev/null; then
  fail "decide: rejects a bad max_update_type"
else ok "decide: rejects a bad max_update_type"; fi

# --- gate -------------------------------------------------------------------
gate() { REPO=o/r BASE=main METHOD=${1:-rebase} bash -c "$gate" >"$t/out" 2>&1; }
repo_settings() { echo "{\"allow_auto_merge\": $1, \"allow_rebase_merge\": $2, \"allow_squash_merge\": true}" | api repos/o/r; }
ruleset_checks() { # <n>
  jq -n --argjson n "$1" '[{type: "deletion"}] + if $n > 0 then [{type: "required_status_checks",
    parameters: {required_status_checks: [range($n) | {context: "c\(.)"}]}}] else [] end' | api repos/o/r/rules/branches/main
}
classic_checks() { # <n>
  jq -n --argjson n "$1" 'if $n > 0 then {protection: {required_status_checks: {contexts: [range($n) | "k\(.)"]}}}
    else {protection: {enabled: false}} end' | api repos/o/r/branches/main
}

repo_settings true true; ruleset_checks 1; classic_checks 0
if gate && grep -q "requires 1 check" "$t/out"; then ok "gate: ruleset check passes"; else fail "gate: ruleset check passes"; fi

ruleset_checks 0; classic_checks 2
if gate && grep -q "requires 2 check" "$t/out"; then ok "gate: classic protection passes"; else fail "gate: classic protection passes"; fi

ruleset_checks 0; classic_checks 0
if ! gate && grep -q "merge before CI" "$t/out"; then ok "gate: no required checks fails"; else fail "gate: no required checks fails"; fi

repo_settings false true; ruleset_checks 1
if ! gate && grep -q "auto-merge is off" "$t/out"; then ok "gate: auto-merge off fails"; else fail "gate: auto-merge off fails"; fi

repo_settings true false
if ! gate && grep -q "rebase merges are off" "$t/out"; then ok "gate: rebase off fails"; else fail "gate: rebase off fails"; fi
if gate squash; then ok "gate: squash allowed when rebase is off"; else fail "gate: squash allowed when rebase is off"; fi
if ! gate fastforward && grep -q "merge_method must be" "$t/out"; then ok "gate: bad method fails"; else fail "gate: bad method fails"; fi

# --- settings-sync.sh -------------------------------------------------------
cat >"$t/repos.yaml" <<'EOF'
settings:
  defaults:
    vulnerability_alerts: true
    security_updates: true
    allow_auto_merge: true
    allow_rebase_merge: true
repos:
  o/r:
    checks: [Lint, Test]
  o/done:
    settings: { allow_rebase_merge: false }
  o/priv:
    checks: [Lint]
  x/other: {}
EOF
sync() { SHIP_REPOS=$t/repos.yaml "$here/settings-sync.sh" "$@" >"$t/out" 2>&1; }
echo '{"default_branch": "main", "allow_auto_merge": false, "allow_rebase_merge": true}' | api repos/o/r
echo '{"enabled": false}' | api repos/o/r/automated-security-fixes
echo '[]' | api repos/o/r/rulesets
echo '{"default_branch": "main", "allow_auto_merge": true, "allow_rebase_merge": false}' | api repos/o/done
echo '{"enabled": true}' | api repos/o/done/automated-security-fixes
echo '' | api repos/o/done/vulnerability-alerts
echo '[]' | api repos/o/done/rules/branches/main
echo '[]' | api repos/o/done/rulesets
echo '{"default_branch": "main", "allow_auto_merge": true, "allow_rebase_merge": true}' | api repos/o/priv
echo '{"enabled": true}' | api repos/o/priv/automated-security-fixes
echo '' | api repos/o/priv/vulnerability-alerts
echo '{"protection": {"required_status_checks": {"contexts": ["CI"]}}}' | api repos/o/done/branches/main
rm -f "$t/api/calls"

if sync o && grep -q "set     vulnerability_alerts: false -> true" "$t/out" &&
  grep -q "set     security_updates: false -> true" "$t/out" &&
  grep -q "set     allow_auto_merge: false -> true" "$t/out" &&
  grep -q "set     checks: none -> Lint, Test" "$t/out" &&
  grep -q "4 change(s); plan only" "$t/out" && ! grep -q "x/other" "$t/out" && [ ! -e "$t/api/calls" ]; then
  ok "sync: plans the owner's repos, writes nothing"
else fail "sync: plans the owner's repos, writes nothing"; fi

if sync o/done && grep -q "ok      allow_rebase_merge: false" "$t/out" &&
  grep -q "branch protection: CI" "$t/out" && grep -q "^0 change" "$t/out"; then
  ok "sync: a repo's settings override the defaults; no checks keeps what it has"
else fail "sync: a repo's settings override the defaults; no checks keeps what it has"; fi

if sync --apply o/r &&
  grep -q "^PUT repos/o/r/vulnerability-alerts" "$t/api/calls" &&
  grep -q "^PUT repos/o/r/automated-security-fixes" "$t/api/calls" &&
  [ "$(grep -n "^PUT repos/o/r/vulnerability-alerts" "$t/api/calls" | cut -d: -f1)" -lt \
    "$(grep -n "^PUT repos/o/r/automated-security-fixes" "$t/api/calls" | cut -d: -f1)" ] &&
  grep -q "^PATCH repos/o/r allow_auto_merge=true$" "$t/api/calls" &&
  sed -n '/^POST repos\/o\/r\/rulesets/,$p' "$t/api/calls" | tail -n +2 |
  jq -e '.rules[0].parameters.required_status_checks == [{context: "Lint"}, {context: "Test"}]
    and .conditions.ref_name.include == ["~DEFAULT_BRANCH"] and .bypass_actors[0].actor_id == 5' >/dev/null; then
  ok "sync: --apply turns on alerts before security updates, patches flags, adds the ruleset"
else fail "sync: --apply turns on alerts before security updates, patches flags, adds the ruleset"; cat "$t/api/calls" 2>/dev/null; fi

echo '[{"id": 42, "name": "ship: required checks"}]' | api repos/o/r/rulesets
echo '{"rules": [{"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "Test"}, {"context": "Lint"}]}}]}' | api repos/o/r/rulesets/42
rm -f "$t/api/calls"
if sync --apply o/r && grep -q "ok      checks: Lint, Test" "$t/out" && ! grep -q rulesets "$t/api/calls"; then
  ok "sync: matching ruleset is left alone"
else fail "sync: matching ruleset is left alone"; fi

echo '{"rules": [{"type": "required_status_checks", "parameters": {"required_status_checks": [{"context": "Lint"}]}}]}' | api repos/o/r/rulesets/42
rm -f "$t/api/calls"
if sync --apply o/r && grep -q "^PUT repos/o/r/rulesets/42" "$t/api/calls" && ! grep -q "^POST" "$t/api/calls"; then
  ok "sync: --apply replaces its own ruleset"
else fail "sync: --apply replaces its own ruleset"; fi

rm -f "$t/api/calls"
if sync --apply o/priv && grep -q "rulesets unavailable" "$t/out" && grep -q "^0 change" "$t/out" &&
  [ ! -e "$t/api/calls" ]; then
  ok "sync: a repo without rulesets (private, Free) is reported, not fatal"
else fail "sync: a repo without rulesets (private, Free) is reported, not fatal"; fi

echo 'settings: { defaults: { allow_rebase: true } }
repos: { o/r: {} }' >"$t/bad.yaml"
if ! SHIP_REPOS=$t/bad.yaml "$here/settings-sync.sh" >"$t/out" 2>&1 && grep -q "unknown settings: allow_rebase" "$t/out"; then
  ok "sync: rejects an unknown setting"
else fail "sync: rejects an unknown setting"; fi

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }

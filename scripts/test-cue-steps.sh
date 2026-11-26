#!/usr/bin/env bash
# Runs cue-release.yml's tag check (extracted with yq, so the workflow stays
# the only copy) against module.cue files: a tag must have the major
# version the module path names, before anything is tagged.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
wf=$here/../.github/workflows/cue-release.yml
step=$(yq '.jobs.settings.steps[] | select(.id == "major") | .run' "$wf")
[ -n "$step" ] || { echo "no major step in $wf"; exit 1; }

fails=0
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; sed 's/^/     /' "$t/log"; fails=$((fails + 1)); }

# check <module line or "-" for no module.cue> <tag>
check() {
  rm -rf "$t/m" && mkdir -p "$t/m"
  if [ "$1" != - ]; then
    mkdir -p "$t/m/cue.mod"
    printf '%s\nlanguage: {\n\tversion: "v0.17.0"\n}\n' "$1" > "$t/m/cue.mod/module.cue"
  fi
  : > "$t/out"
  (cd "$t/m" && TAG=$2 GITHUB_OUTPUT="$t/out" bash -c "$step") > "$t/log" 2>&1
}

v0='module: "github.com/unbound-force/intake-kit@v0"'
if check "$v0" v0.4.0 && grep -qxF 'module=github.com/unbound-force/intake-kit@v0' "$t/out"; then
  ok "a v0 tag for an @v0 module passes"
else fail "a v0 tag for an @v0 module passes"; fi

if check "$v0" v0.4.0-rc.1; then ok "a prerelease tag passes"; else fail "a prerelease tag passes"; fi

if ! check "$v0" v1.0.0 && grep -q 'major v1, but the module is' "$t/log"; then
  ok "a v1 tag for an @v0 module fails"
else fail "a v1 tag for an @v0 module fails"; fi

if check 'module: "example.com/m@v2"' v2.1.0; then ok "an @v2 module takes v2 tags"; else fail "an @v2 module takes v2 tags"; fi

if ! check 'module: "example.com/m"' v0.1.0 && grep -q 'no major version' "$t/log"; then
  ok "a module path without @vN fails"
else fail "a module path without @vN fails"; fi

if ! check - v0.1.0 && grep -q 'not a CUE module' "$t/log"; then
  ok "no cue.mod/module.cue fails"
else fail "no cue.mod/module.cue fails"; fi

if [ "$fails" -ne 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

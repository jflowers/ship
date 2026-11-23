#!/usr/bin/env bash
# Runs go-release.yml's "audit" step (extracted with yq) against the real
# GoReleaser cask in testdata/. macOS only: brew audits on_macos stanzas
# only on a Mac.
#
# The cask as GoReleaser renders replicator's custom_block uses
# "#{staged_path}", which Homebrew 7's postflight_steps can't read; the
# audit must reject it and accept "{{staged_path}}".
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
wf=$here/../.github/workflows/go-release.yml
step=$(yq '.jobs.publish-cask.steps[] | select(.id == "audit") | .run' "$wf")
[ -n "$step" ] || { echo "no audit step in $wf"; exit 1; }
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1

fails=0
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; sed 's/^/     /' "$t/log"; fails=$((fails + 1)); }

# stage <sed expr>: a one-commit tap holding the fixture cask, edited.
stage() {
  rm -rf "$t/tap" && mkdir -p "$t/tap/Casks"
  sed -e 's/version "0.5.4-rc2-SNAPSHOT-d59a3e8"/version "0.5.4"/' -e "$1" \
    "$here/testdata/cask.rb" > "$t/tap/Casks/replicator.rb"
  git -C "$t/tap" init -q
  git -C "$t/tap" add -A
  git -C "$t/tap" -c user.name=test -c user.email=test@example.com commit -qm cask
}
audit() { (cd "$t" && TAP_DIR=tap CASK=replicator bash -c "$step") > "$t/log" 2>&1; }

stage 's/#{staged_path}/{{staged_path}}/'
if audit; then ok "valid cask passes"; else fail "valid cask passes"; fi

stage 's/^//'
if ! audit && grep -q 'staged_path' "$t/log"; then
  ok "#{staged_path} in postflight_steps is rejected"
else fail "#{staged_path} in postflight_steps is rejected"; fi

if [ "$fails" -ne 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

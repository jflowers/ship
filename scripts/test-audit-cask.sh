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

# stage <sed expr> [cask]: a one-commit tap holding the fixture cask, edited
# (and renamed to [cask]).
stage() {
  cask=${2:-replicator}
  rm -rf "$t/tap" && mkdir -p "$t/tap/Casks"
  sed -e 's/version "0.5.4-rc2-SNAPSHOT-d59a3e8"/version "0.5.4"/' -e "$1" \
    -e "s/^cask \"replicator\"/cask \"$cask\"/" \
    "$here/testdata/cask.rb" > "$t/tap/Casks/$cask.rb"
  git -C "$t/tap" init -q
  git -C "$t/tap" add -A
  git -C "$t/tap" -c user.name=test -c user.email=test@example.com commit -qm cask
}
audit() { (cd "$t" && TAP_DIR=tap CASK=$cask bash -c "$step") > "$t/log" 2>&1; }

stage 's/#{staged_path}/{{staged_path}}/'
if audit; then ok "valid cask passes"; else fail "valid cask passes"; fi

stage 's/^//'
if ! audit && grep -q 'staged_path' "$t/log"; then
  ok "#{staged_path} in postflight_steps is rejected"
else fail "#{staged_path} in postflight_steps is rejected"; fi

# A tap's cask may share a homebrew/core formula's name (unbound-force's
# gaze); only homebrew/cask forbids that.
stage 's/#{staged_path}/{{staged_path}}/' gaze
if audit; then ok "cask named like a core formula passes"; else fail "cask named like a core formula passes"; fi

# mac-app-release.yml: the cask its writer makes for an app passes its
# audit, which must stay the same as go-release.yml's.
macwf=$here/../.github/workflows/mac-app-release.yml
macaudit=$(yq '.jobs.cask.steps[] | select(.id == "audit") | .run' "$macwf")
write=$(yq '.jobs.cask.steps[] | select(.id == "write") | .run' "$macwf")
if [ "$macaudit" = "$step" ]; then ok "mac-app-release.yml audits like go-release.yml"
else : > "$t/log"; fail "mac-app-release.yml audits like go-release.yml"; fi
app_cask() { # <macos>
  cask=gh-hud
  rm -rf "$t/tap" && mkdir -p "$t/tap/Casks"
  (cd "$t/tap/Casks" && CASK=gh-hud VERSION=0.3.20 ZIP=gh-hud-app_0.3.20.zip APP=build/gh-hud.app \
    MACOS=$1 HOMEPAGE='' DESC="Dashboard for GitHub work and coding agents, a client of the gh-hud hub" \
    SHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
    GITHUB_REPOSITORY=jflowers/gh-hud bash -c "$write" >/dev/null)
  git -C "$t/tap" init -q
  git -C "$t/tap" add -A
  git -C "$t/tap" -c user.name=test -c user.email=test@example.com commit -qm cask
}
app_cask sonoma
if audit; then ok "a Mac app's cask passes"; else fail "a Mac app's cask passes"; fi
app_cask ""
if audit; then ok "a Mac app's cask without depends_on passes"; else fail "a Mac app's cask without depends_on passes"; fi

if [ "$fails" -ne 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

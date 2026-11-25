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

# go-release.yml's formula check: brew loads unbound-force's real formula
# (GoReleaser 2), and not one with a syntax error. Reads only; no install.
loads=$(yq '.jobs.publish-cask.steps[] | select(.id == "formula-loads") | .run' "$wf")
[ -n "$loads" ] || { echo "no formula-loads step in $wf"; exit 1; }
formula_tap() { # <sed expr>
  rm -rf "$t/tap" && mkdir -p "$t/tap/Formula"
  sed -e "$1" "$here/testdata/formula.rb" > "$t/tap/Formula/unbound-force.rb"
  git -C "$t/tap" init -q && git -C "$t/tap" add -A
  git -C "$t/tap" -c user.name=test -c user.email=test@example.com commit -qm formula
}
formula_loads() { (cd "$t" && TAP_DIR=tap FORMULA=unbound-force bash -c "$loads") > "$t/log" 2>&1; }
formula_tap 's/^//'
if formula_loads; then ok "formula check: GoReleaser's formula loads"; else fail "formula check: GoReleaser's formula loads"; fi
formula_tap 's/^  on_linux do$/  on_linux do do/'
if formula_loads; then fail "formula check: a broken formula fails"; else ok "formula check: a broken formula fails"; fi

# go-release.yml's cask install check: installs a cask whose url is a local
# archive, then runs the caller's check. It really installs, so only on CI
# (a disposable runner), never on a developer's Mac.
install=$(yq '.jobs.publish-cask.steps[] | select(.id == "install") | .run' "$wf")
[ -n "$install" ] || { echo "no install step in $wf"; exit 1; }
if [ "${CI:-}" = true ]; then
  cask=ship-install-demo
  mkdir -p "$t/pkg" && printf '#!/bin/sh\necho demo ok\n' > "$t/pkg/$cask" && chmod +x "$t/pkg/$cask"
  tar -czf "$t/demo.tar.gz" -C "$t/pkg" "$cask"
  demo_sha=$(shasum -a 256 "$t/demo.tar.gz" | cut -d' ' -f1)
  rm -rf "$t/tap" && mkdir -p "$t/tap/Casks"
  cat > "$t/tap/Casks/$cask.rb" <<EOF
cask "$cask" do
  version "1.0.0"
  sha256 "$demo_sha"

  url "file://$t/demo.tar.gz"
  name "$cask"
  desc "Test cask for ship's install check"
  homepage "https://github.com/jflowers/ship"

  binary "$cask"
end
EOF
  git -C "$t/tap" init -q && git -C "$t/tap" add -A
  git -C "$t/tap" -c user.name=test -c user.email=test@example.com commit -qm cask
  install_check() { (cd "$t" && TAP_DIR=tap CASK=$cask CHECK=$1 bash -c "$install") > "$t/log" 2>&1; }
  # shellcheck disable=SC2016 # expanded by the step, not here
  if install_check '"$HOMEBREW_PREFIX/bin/ship-install-demo" | grep -qx "demo ok"' &&
    ! brew list --cask "$cask" >/dev/null 2>&1; then
    ok "install check: the cask installs, the check passes, and it's removed after"
  else fail "install check: the cask installs, the check passes, and it's removed after"; fi
  # shellcheck disable=SC2016
  if install_check 'test -e "$HOMEBREW_PREFIX/bin/not-installed"'; then
    fail "install check: a failing check fails the step"
  else ok "install check: a failing check fails the step"; fi
else
  echo "skip install check: it installs a cask, so it runs only on CI"
fi

if [ "$fails" -ne 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

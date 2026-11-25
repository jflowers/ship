#!/usr/bin/env bash
# Runs mac-app-release.yml's settings check and cask writer, and
# tag-release.yml's settings check (extracted with yq, so the workflows stay
# the only copy). Runs anywhere; the brew audit of a written cask is in
# test-audit-cask.sh (macOS).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
wf=$here/../.github/workflows/mac-app-release.yml
tagwf=$here/../.github/workflows/tag-release.yml
settings=$(yq '.jobs.settings.steps[] | select(.id == "s") | .run' "$wf")
write=$(yq '.jobs.cask.steps[] | select(.id == "write") | .run' "$wf")
branch=$(yq '.jobs.settings.steps[] | select(.id == "s") | .run' "$tagwf")
[ -n "$settings" ] && [ -n "$write" ] && [ -n "$branch" ] || { echo "steps missing"; exit 1; }

fails=0
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; sed 's/^/     /' "$t/err" 2>/dev/null || true; fails=$((fails + 1)); }

# --- mac-app-release.yml settings ---------------------------------------
# All five signing secrets and the tap token are set unless named in $UNSET.
run_settings() { # <tag> <app> <tap> <cask_desc> [zip_prefix] [cask]
  : > "$t/out"
  local env=(TAG="$1" APP="$2" TAP="$3" CASK_DESC="$4" ZIP_PREFIX="${5:-}" CASK="${6:-}"
    REPO=gh-hud GITHUB_OUTPUT="$t/out")
  local n
  for n in MACOS_SIGN_P12 MACOS_SIGN_PASSWORD MACOS_NOTARY_KEY MACOS_NOTARY_KEY_ID MACOS_NOTARY_ISSUER_ID HOMEBREW_TAP_TOKEN; do
    if [[ " ${UNSET:-} " == *" $n "* ]]; then env+=("HAS_$n=false"); else env+=("HAS_$n=true"); fi
  done
  env "${env[@]}" bash -c "$settings" > "$t/err" 2>&1
}
expect_settings() { # <want: pass|fail> <name> <args...>; then the output lines wanted
  local want=$1 name=$2 got line
  shift 2
  local args=() wanted=()
  while (($#)) && [ "$1" != -- ]; do args+=("$1"); shift; done
  (($#)) && shift && wanted=("$@")
  if run_settings "${args[@]}"; then got=pass; else got=fail; fi
  if [ "$got" != "$want" ]; then fail "settings: $name (got $got)"; return; fi
  for line in "${wanted[@]+"${wanted[@]}"}"; do
    grep -qxF "$line" "$t/out" || { fail "settings: $name (no '$line'; got: $(tr '\n' ' ' < "$t/out"))"; return; }
  done
  ok "settings: $name"
}

desc="Dashboard for GitHub work"
expect_settings pass "a release with a cask" v0.3.20 build/gh-hud.app jflowers/homebrew-tools "$desc" -- \
  version=0.3.20 zip=gh-hud-app_0.3.20.zip cask=gh-hud publish_cask=true
expect_settings pass "zip_prefix and cask override the repo name" v1.0.0 build/X.app o/tap "$desc" x-mac x -- \
  zip=x-mac_1.0.0.zip cask=x
expect_settings pass "no tap, no cask" v1.0.0 build/X.app "" "" -- publish_cask=false
expect_settings pass "a prerelease leaves the cask alone" v1.0.0-rc.1 build/X.app o/tap "$desc" -- \
  version=1.0.0-rc.1 publish_cask=false
expect_settings fail "a tag that isn't vX.Y.Z" 1.0.0 build/X.app "" ""
expect_settings fail "a branch name for a tag" main build/X.app "" ""
expect_settings fail "app isn't an .app" v1.0.0 build/X "" ""
expect_settings fail "tap without cask_desc" v1.0.0 build/X.app o/tap ""
UNSET=HOMEBREW_TAP_TOKEN expect_settings fail "tap without its token" v1.0.0 build/X.app o/tap "$desc"
UNSET=HOMEBREW_TAP_TOKEN expect_settings pass "no tap needs no token" v1.0.0 build/X.app "" ""
UNSET="MACOS_NOTARY_KEY_ID" expect_settings fail "a signing secret missing" v1.0.0 build/X.app "" ""
if UNSET="MACOS_SIGN_P12 MACOS_NOTARY_KEY" run_settings v1.0.0 build/X.app "" "" ||
  ! grep -q "missing secrets: MACOS_SIGN_P12 MACOS_NOTARY_KEY" "$t/err"; then
  fail "settings: the error names the missing secrets"
else ok "settings: the error names the missing secrets"; fi

# --- mac-app-release.yml cask writer --------------------------------------
sha=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
write_cask() { # <version> <zip> <app> <macos> [sha] [homepage]
  rm -f "$t/gh-hud.rb"
  (cd "$t" && CASK=gh-hud VERSION=$1 ZIP=$2 APP=$3 MACOS=$4 SHA256=${5-$sha} HOMEPAGE=${6:-} \
    DESC="$desc" GITHUB_REPOSITORY=jflowers/gh-hud bash -c "$write") > "$t/err" 2>&1
}
if write_cask 0.3.20 gh-hud-app_0.3.20.zip build/gh-hud.app sonoma &&
  diff -u - "$t/gh-hud.rb" > "$t/err" <<EOF
# Written by jflowers/gh-hud's release (jflowers/ship mac-app-release.yml). Edits are overwritten.
cask "gh-hud" do
  version "0.3.20"
  sha256 "$sha"

  url "https://github.com/jflowers/gh-hud/releases/download/v#{version}/gh-hud-app_#{version}.zip"
  name "gh-hud"
  desc "$desc"
  homepage "https://github.com/jflowers/gh-hud"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "gh-hud.app"
end
EOF
then ok "cask: gh-hud's cask"; else fail "cask: gh-hud's cask"; fi

if write_cask 1.0.0 x-mac_1.0.0.zip build/Some\ App.app "" "$sha" https://example.com &&
  grep -qxF '  url "https://github.com/jflowers/gh-hud/releases/download/v#{version}/x-mac_#{version}.zip"' "$t/gh-hud.rb" &&
  grep -qxF '  app "Some App.app"' "$t/gh-hud.rb" &&
  grep -qxF '  homepage "https://example.com"' "$t/gh-hud.rb" &&
  ! grep -q depends_on "$t/gh-hud.rb"; then
  ok "cask: no macos, another zip, app and homepage"
else fail "cask: no macos, another zip, app and homepage"; fi

if write_cask 1.0.0 x_1.0.0.zip build/X.app "" ""; then
  fail "cask: no sha256 from the app job fails"
else ok "cask: no sha256 from the app job fails"; fi

# --- steps shared with go-release.yml, tested there (test-steps.sh) -----
gowf=$here/../.github/workflows/go-release.yml
same() { # <name> <go-release job> <mac-app-release job> <step name>
  local a b
  a=$(yq ".jobs.$2.steps[] | select(.name == \"$4\") | .run" "$gowf")
  b=$(yq ".jobs.$3.steps[] | select(.name == \"$4\") | .run" "$wf")
  : > "$t/err"
  if [ -n "$a" ] && [ "$a" = "$b" ]; then ok "same as go-release.yml: $1"
  else diff <(echo "$a") <(echo "$b") > "$t/err" || true; fail "same as go-release.yml: $1"; fi
}
same "the Developer ID import" sign-macos app "Import the Developer ID"
same "the tap commit" publish-cask cask "Commit the cask in a clone of the tap"
same "the tap push and its retry" publish-cask cask "Push to the tap"

# --- tag-release.yml settings ----------------------------------------------
if REF=refs/heads/master DEFAULT_BRANCH=master bash -c "$branch" > "$t/err" 2>&1; then
  ok "tag-release: runs on the default branch"
else fail "tag-release: runs on the default branch"; fi
if REF=refs/heads/feature DEFAULT_BRANCH=master bash -c "$branch" > "$t/err" 2>&1; then
  fail "tag-release: refuses another branch"
else ok "tag-release: refuses another branch"; fi

if [ "$fails" -ne 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

#!/usr/bin/env bash
# Runs sync-check.sh against a fixture repos.yaml and fixture workflows
# (--dir), one repo at a time: what's in sync passes, and each kind of
# drift is reported.
# Backticks in the expected Markdown are literal, as is ${{ }} in fixtures.
# shellcheck disable=SC2016,SC2001
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
fails=0
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; sed 's/^/     /' "$t/out"; fails=$((fails + 1)); }

new=1111111111111111111111111111111111111111
old=2222222222222222222222222222222222222222
printf '%s v0.10.0\n%s v0.9.0\n' "$new" "$old" > "$t/tags"

# repo <entry yaml> <release.yml>: one repo, acme/tool, and its workflow
repo() {
  rm -rf "$t/acme" && mkdir -p "$t/acme/tool"
  cat > "$t/repos.yaml" <<EOF
secrets:
  sets:
    macos-sign:
      MACOS_SIGN_P12: x
      MACOS_NOTARY_KEY: x
repos:
  acme/tool:
$(sed 's/^/    /' <<<"$1")
EOF
  printf '%s\n' "$2" > "$t/acme/tool/release.yml"
}
run() { REPOS_YAML=$t/repos.yaml "$here/sync-check.sh" --dir "$t" > "$t/out" 2>&1; }

entry='kinds: [go-cli, cask]
secrets: [macos-sign]
tap: acme/homebrew-tap
workflow: go-release.yml@v0.10.0
mise: go:github.com/acme/tool/cmd/tool'
caller() { # <sha> [extra with lines] [secrets lines]
  cat <<EOF
jobs:
  release:
    uses: jflowers/ship/.github/workflows/go-release.yml@$1 # pin
    with:
      tag: v1.0.0
      tap: acme/homebrew-tap
      go_install: github.com/acme/tool/cmd/tool
      tap_install_check: tool --version
${2:-}
    secrets:
      MACOS_SIGN_P12: \${{ secrets.MACOS_SIGN_P12 }}
      MACOS_NOTARY_KEY: \${{ secrets.MACOS_NOTARY_KEY }}
      HOMEBREW_TAP_TOKEN: \${{ secrets.HOMEBREW_TAP_TOKEN }}
${3:-}
EOF
}

repo "$entry" "$(caller $new)"
if run && grep -q '✅ \*\*acme/tool\*\* (v0.10.0)' "$t/out" && ! grep -q '⚠️' "$t/out"; then
  ok "a repo in sync passes, without warnings"
else fail "a repo in sync passes, without warnings"; fi

repo "$entry" "$(caller $old)"
if run && grep -q 'go-release.yml` is on v0.9.0 (latest is v0.10.0)' "$t/out" &&
  grep -q 'pinned to v0.9.0; repos.yaml says v0.10.0' "$t/out"; then
  ok "an older pin warns, but passes"
else fail "an older pin warns, but passes"; fi

repo "$entry" "$(caller 3333333333333333333333333333333333333333)"
if ! run && grep -q 'pinned to `333333333333`, which is no ship tag' "$t/out"; then
  ok "a pin that's no ship tag fails"
else fail "a pin that's no ship tag fails"; fi

repo "$entry" "$(caller $new | sed 's/go-release.yml/npm-release.yml/')"
if ! run && grep -q "doesn't call \`go-release.yml\`" "$t/out"; then
  ok "not calling the listed workflow fails"
else fail "not calling the listed workflow fails"; fi

repo "$entry" "$(caller $new | sed 's|tap: acme/homebrew-tap|tap: acme/homebrew-other|')"
if ! run && grep -q "\`tap\` is 'acme/homebrew-other', not acme/homebrew-tap" "$t/out"; then
  ok "another tap fails"
else fail "another tap fails"; fi

repo "$entry" "$(caller $new | grep -v MACOS_NOTARY_KEY)"
if ! run && grep -q "doesn't use secret MACOS_NOTARY_KEY (macos-sign)" "$t/out"; then
  ok "a missing secret fails"
else fail "a missing secret fails"; fi

# A secret the caller's own job uses (gh-hud's APK) counts.
repo "$entry" "$(caller $new '' '  own:
    runs-on: ubuntu-latest
    steps:
      - run: echo
        env:
          KEY: ${{ secrets.MACOS_NOTARY_KEY }}' | grep -v 'MACOS_NOTARY_KEY: \${{')"
if run; then ok "a secret used in the caller's own job counts"; else fail "a secret used in the caller's own job counts"; fi

repo "$entry" "$(caller $new | sed 's|go_install: .*|go_install: github.com/acme/tool|')"
if ! run && grep -q '`go_install` is github.com/acme/tool; mise installs github.com/acme/tool/cmd/tool' "$t/out"; then
  ok "go_install other than mise's package fails"
else fail "go_install other than mise's package fails"; fi

repo "$entry" "$(caller $new | grep -v 'go_install:\|tap_install_check:')"
if run && grep -q '⚠️ no `go_install`' "$t/out" && grep -q '⚠️ no `tap_install_check`' "$t/out"; then
  ok "missing post-release checks warn, but pass"
else fail "missing post-release checks warn, but pass"; fi

repo "kinds: [npm]
workflow: own" "jobs: {}"
if run && ! grep -q 'acme/tool' "$t/out"; then ok "repos not on ship are skipped"; else fail "repos not on ship are skipped"; fi

if [ "$fails" -ne 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

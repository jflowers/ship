#!/usr/bin/env bash
# Runs npm-release.yml's shell steps (extracted with yq, so the workflow
# stays the only copy): the settings check, and the package.json check
# against fixture package.json files with a fake `npm view`. Needs node.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
wf=$here/../.github/workflows/npm-release.yml
settings=$(yq '.jobs.settings.steps[] | select(.id == "s") | .run' "$wf")
package=$(yq '.jobs.publish.steps[] | select(.id == "package") | .run' "$wf")
[ -n "$settings" ] && [ -n "$package" ] || { echo "steps missing from $wf"; exit 1; }

fails=0
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin" "$t/pkg"

# Fake npm: `npm view <name>@<version> version` succeeds only for versions
# listed in $t/published.
cat > "$t/bin/npm" <<'EOF'
#!/usr/bin/env bash
[ "$1" = view ] || exit 2
grep -qxF "$2" "$PUBLISHED"
EOF
chmod +x "$t/bin/npm"

ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; sed 's/^/     /' "$t/err" 2>/dev/null || true; fails=$((fails + 1)); }

# settings <ref> <version_from> <npm_version> <stage>
run_settings() {
  REF=$1 DEFAULT_BRANCH=main VERSION_FROM=$2 NPM_VERSION=$3 STAGE=$4 \
    bash -c "$settings" > "$t/err" 2>&1
}
expect_settings() { # <want: pass|fail> <name> <args...>
  local want=$1 name=$2
  shift 2
  if run_settings "$@"; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then ok "settings: $name"; else fail "settings: $name (got $got)"; fi
}

expect_settings pass "main, package, npm 11.21.2" refs/heads/main package 11.21.2 false
expect_settings fail "not the default branch" refs/heads/feature package 11.21.2 false
expect_settings fail "unknown version_from" refs/heads/main both 11.21.2 false
expect_settings fail "npm too old for trusted publishing" refs/heads/main package 11.4.0 false
expect_settings fail "npm too old to stage" refs/heads/main tag 11.14.9 true
expect_settings pass "npm 11.15.0 can stage" refs/heads/main tag 11.15.0 true
expect_settings pass "npm 12 is newer, not older" refs/heads/main package 12.2.3 false

# package <tag> <version_from> <package.json>; outputs land in $t/out
run_package() {
  printf '%s\n' "$3" > "$t/pkg/package.json"
  : > "$t/out"
  (cd "$t/pkg" && PATH="$t/bin:$PATH" PUBLISHED="$t/published" GITHUB_OUTPUT="$t/out" \
    GITHUB_REPOSITORY=acme/widget TAG=$1 VERSION_FROM=$2 bash -c "$package") > "$t/err" 2>&1
}
pkg() { # <version> <repository json>
  printf '{"name": "widget", "version": "%s", "repository": %s}' "$1" "$2"
}
expect_package() { # <want: pass|fail> <name> <tag> <version_from> <package.json> [output line]
  local want=$1 name=$2 got
  if run_package "$3" "$4" "$5"; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ] && { [ -z "${6:-}" ] || grep -qxF "$6" "$t/out"; }; then
    ok "package: $name"
  else fail "package: $name (got $got; outputs: $(tr '\n' ' ' < "$t/out"))"; fi
}

: > "$t/published"
https='{"type": "git", "url": "git+https://github.com/acme/widget.git"}'
expect_package pass "version matches the tag" v1.2.3 package "$(pkg 1.2.3 "$https")" "version=1.2.3"
expect_package pass "release goes to latest" v1.2.3 package "$(pkg 1.2.3 "$https")" "dist_tag=latest"
expect_package pass "prerelease goes to next" v1.3.0-rc.1 package "$(pkg 1.3.0-rc.1 "$https")" "dist_tag=next"
expect_package fail "version doesn't match the tag" v1.2.4 package "$(pkg 1.2.3 "$https")"
expect_package pass "version from the tag ignores the placeholder" v0.3.0 tag "$(pkg 0.0.0-development "$https")" "version=0.3.0"
expect_package pass "repository as a plain https string" v1.2.3 package "$(pkg 1.2.3 '"https://github.com/acme/widget"')"
expect_package pass "repository as git@github.com:" v1.2.3 package "$(pkg 1.2.3 '{"url": "git@github.com:acme/widget.git"}')"
expect_package pass "repository as git+ssh://git@" v1.2.3 package "$(pkg 1.2.3 '{"url": "git+ssh://git@github.com/acme/widget.git"}')"
expect_package fail "repository is another repo" v1.2.3 package "$(pkg 1.2.3 '{"url": "git+https://github.com/acme/other.git"}')"
expect_package fail "repository is a fork's prefix" v1.2.3 package "$(pkg 1.2.3 '{"url": "git+https://github.com/acme/widget-fork.git"}')"
expect_package fail "no repository" v1.2.3 package '{"name": "widget", "version": "1.2.3"}'
echo "widget@1.2.3" > "$t/published"
expect_package fail "version already on npm" v1.2.3 package "$(pkg 1.2.3 "$https")"
expect_package pass "only that version is taken" v1.2.4 package "$(pkg 1.2.4 "$https")"

if [ "$fails" -ne 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

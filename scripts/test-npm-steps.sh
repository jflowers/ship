#!/usr/bin/env bash
# Runs npm-release.yml's shell steps (extracted with yq, so the workflow
# stays the only copy): the settings check, the package.json check against
# fixture package.json files with a fake `npm view`, and the GitHub release
# step with a fake `gh`. Needs node.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
wf=$here/../.github/workflows/npm-release.yml
settings=$(yq '.jobs.settings.steps[] | select(.id == "s") | .run' "$wf")
early=$(yq '.jobs.settings.steps[] | select(.id == "package") | .run' "$wf")
package=$(yq '.jobs.publish.steps[] | select(.id == "package") | .run' "$wf")
release=$(yq '.jobs.github-release.steps[] | select(.id == "release") | .run' "$wf")
[ -n "$settings" ] && [ -n "$early" ] && [ -n "$package" ] && [ -n "$release" ] || { echo "steps missing from $wf"; exit 1; }

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
# Fake gh: `gh release view <tag>` succeeds for tags listed in $RELEASES;
# `gh release create ...` records its arguments in $CREATED.
cat > "$t/bin/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = release ] || exit 2
case "$2" in
  view) grep -qxF "$3" "$RELEASES" ;;
  create) shift 2; echo "$*" >> "$CREATED" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$t/bin/npm" "$t/bin/gh"

ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; sed 's/^/     /' "$t/err" 2>/dev/null || true; fails=$((fails + 1)); }

# settings <ref> <version_from> <npm_version> <stage> <owner type>; outputs
# land in $t/out
run_settings() {
  : > "$t/out"
  REF=$1 DEFAULT_BRANCH=main VERSION_FROM=$2 NPM_VERSION=$3 STAGE=$4 OWNER_TYPE=$5 \
    GITHUB_OUTPUT="$t/out" bash -c "$settings" > "$t/err" 2>&1
}
expect_settings() { # <want: pass|fail> <name> <ref> <version_from> <npm> <stage> <owner> [output line]
  local want=$1 name=$2 got
  shift 2
  if run_settings "$1" "$2" "$3" "$4" "$5"; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ] && { [ -z "${6:-}" ] || grep -qxF "$6" "$t/out"; }; then
    ok "settings: $name"
  else fail "settings: $name (got $got; outputs: $(tr '\n' ' ' < "$t/out"))"; fi
}

expect_settings pass "main, package, npm 11.21.2" refs/heads/main package 11.21.2 false User
expect_settings fail "not the default branch" refs/heads/feature package 11.21.2 false User
expect_settings fail "unknown version_from" refs/heads/main both 11.21.2 false User
expect_settings fail "npm too old for trusted publishing" refs/heads/main package 11.4.0 false User
expect_settings fail "npm too old to stage" refs/heads/main tag 11.14.9 true User
expect_settings pass "npm 11.15.0 can stage" refs/heads/main tag 11.15.0 true User
expect_settings pass "npm 12 is newer, not older" refs/heads/main package 12.2.3 false User
expect_settings pass "auto stages in an organization" refs/heads/main tag 11.21.2 auto Organization "stage=true"
expect_settings pass "auto publishes in a personal account" refs/heads/main package 11.21.2 auto User "stage=false"
expect_settings fail "auto needs npm new enough to stage in an organization" refs/heads/main package 11.14.0 auto Organization
expect_settings pass "auto lets older npm publish in a personal account" refs/heads/main package 11.14.0 auto User "stage=false"
expect_settings fail "auto with no owner type" refs/heads/main package 11.21.2 auto ""
expect_settings pass "true stages anywhere" refs/heads/main package 11.21.2 true User "stage=true"
expect_settings pass "false publishes anywhere" refs/heads/main package 11.21.2 false Organization "stage=false"
expect_settings fail "unknown stage" refs/heads/main package 11.21.2 yes User

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
expect_package pass "a new version gets published" v1.2.3 package "$(pkg 1.2.3 "$https")" "published=false"
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

# settings' package.json check: the same rules, on the commit about to be
# tagged, before preflight. <want> <name> <tag> <version_from> <package.json>
expect_early() {
  local want=$1 name=$2 got
  printf '%s\n' "$5" > "$t/pkg/package.json"
  if (cd "$t/pkg" && GITHUB_REPOSITORY=acme/widget TAG=$3 VERSION_FROM=$4 \
    bash -c "$early") > "$t/err" 2>&1; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then ok "settings package.json: $name"
  else fail "settings package.json: $name (got $got)"; fi
}
expect_early pass "version matches the tag" v1.2.3 package "$(pkg 1.2.3 "$https")"
expect_early fail "version not bumped for the tag" v1.3.0 package "$(pkg 1.2.3 "$https")"
expect_early pass "version from the tag ignores the placeholder" v0.3.0 tag "$(pkg 0.0.0-development "$https")"
expect_early pass "repository as git@github.com:" v1.2.3 package "$(pkg 1.2.3 '{"url": "git@github.com:acme/widget.git"}')"
expect_early fail "repository is another repo" v1.2.3 package "$(pkg 1.2.3 '{"url": "git+https://github.com/acme/other.git"}')"
expect_early fail "repository is another repo, version from the tag" v1.2.3 tag "$(pkg 0.0.0-development '{"url": "git+https://github.com/acme/other.git"}')"
expect_early fail "no repository" v1.2.3 package '{"name": "widget", "version": "1.2.3"}'
if expect_early fail "says nothing was tagged" v1.3.0 package "$(pkg 1.2.3 "$https")" >/dev/null && grep -q "Nothing was tagged" "$t/err"; then
  ok "settings package.json: the error says nothing was tagged"
else fail "settings package.json: the error says nothing was tagged"; fi

echo "widget@1.2.3" > "$t/published"
expect_package pass "version already on npm is skipped, not failed" v1.2.3 package "$(pkg 1.2.3 "$https")" "published=true"
expect_package pass "only that version is taken" v1.2.4 package "$(pkg 1.2.4 "$https")" "published=false"
expect_package fail "a mismatched version still fails when published" v1.2.3 package "$(pkg 1.2.2 "$https")"

# release <tag>; what `gh release create` got lands in $t/created
run_release() {
  : > "$t/created"
  PATH="$t/bin:$PATH" RELEASES="$t/releases" CREATED="$t/created" TAG=$1 \
    bash -c "$release" > "$t/err" 2>&1
}
: > "$t/releases"
if run_release v1.2.3 && [ "$(cat "$t/created")" = "v1.2.3 --verify-tag --generate-notes" ]; then
  ok "release: created with generated notes"
else fail "release: created with generated notes (created: $(cat "$t/created"))"; fi
if run_release v1.3.0-rc.1 && [ "$(cat "$t/created")" = "v1.3.0-rc.1 --verify-tag --generate-notes --prerelease" ]; then
  ok "release: prerelease tag makes a prerelease"
else fail "release: prerelease tag makes a prerelease (created: $(cat "$t/created"))"; fi
echo v1.2.3 > "$t/releases"
if run_release v1.2.3 && [ ! -s "$t/created" ]; then
  ok "release: an existing release is left alone"
else fail "release: an existing release is left alone (created: $(cat "$t/created"))"; fi

if [ "$fails" -ne 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

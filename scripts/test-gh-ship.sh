#!/usr/bin/env bash
# Runs bin/gh-ship's `release` against a fake gh: every check that stops a
# release before it's dispatched, and the dispatch itself.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
ghship=$here/../bin/gh-ship
fails=0
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; sed 's/^/     /' "$t/out"; fails=$((fails + 1)); }

cat > "$t/repos.yaml" <<'EOF'
repos:
  acme/tool:
    workflow: go-release.yml@v0.10.0
EOF

# Fake gh: answers from $t/fix (tags, failed, ahead, workflows/*.yml) and
# logs workflow runs to $t/fix/dispatched. It prints what the real call's -q
# would.
mkdir -p "$t/bin"
cat > "$t/bin/gh" <<'EOF'
#!/usr/bin/env bash
fix=$FIX
case "$1 $2" in
  "api repos/acme/tool/contents/.github/workflows") ls "$fix/workflows" | grep -E '\.ya?ml$' ;;
  "api repos/acme/tool/contents/.github/workflows/"*) base64 < "$fix/workflows/${2##*/}" ;;
  "api repos/acme/tool/tags?per_page=100") cat "$fix/tags" ;;
  "api repos/acme/tool/git/ref/tags/"*) grep -qx "${2##*/}" "$fix/tags" ;;
  "api repos/acme/tool") echo main ;;
  "api repos/acme/tool/commits/main") echo 0123456789abcdef ;;
  "api repos/acme/tool/compare/"*) cat "$fix/ahead" ;;
  "api repos/acme/tool/commits/0123456789abcdef/check-runs?per_page=100") cat "$fix/failed" ;;
  "workflow run") echo "$*" >> "$fix/dispatched" ;;
  "run list") echo 4242 ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$t/bin/gh"

caller='on:
  workflow_dispatch:
    inputs:
      tag:
        type: string
jobs:
  release:
    uses: jflowers/ship/.github/workflows/go-release.yml@abc # v0.10.0'

# fixture: defaults, then the caller's overrides
fixture() {
  rm -rf "$t/fix" && mkdir -p "$t/fix/workflows"
  printf 'v1.2.0\nv1.1.0\nnot-semver\n' > "$t/fix/tags"
  echo 3 > "$t/fix/ahead"
  : > "$t/fix/failed"
  printf '%s\n' "$caller" > "$t/fix/workflows/release.yml"
  printf 'on: push\njobs:\n  test:\n    runs-on: ubuntu-latest\n' > "$t/fix/workflows/ci.yml"
}
release() { FIX=$t/fix PATH="$t/bin:$PATH" REPOS_YAML=$t/repos.yaml GH_SHIP_POLL=0 "$ghship" release "$@" > "$t/out" 2>&1 < /dev/null; }
# refused <name> <message> <args...>: stops with the message, dispatches nothing
refused() {
  local name=$1 msg=$2
  shift 2
  if ! release "$@" && grep -qF "$msg" "$t/out" && [ ! -e "$t/fix/dispatched" ]; then ok "$name"; else fail "$name"; fi
}

fixture
if release acme/tool v1.3.0 --yes && grep -qxF 'workflow run release.yml -R acme/tool --ref main -f tag=v1.3.0' "$t/fix/dispatched" &&
  grep -qF 'https://github.com/acme/tool/actions/runs/4242' "$t/out" &&
  grep -qF 'v1.3.0 (latest v1.2.0, 3 commits since), release.yml on main @ 0123456' "$t/out"; then
  ok "a new tag dispatches the release workflow and prints the run"
else fail "a new tag dispatches the release workflow and prints the run"; fi

fixture; refused "without --yes and no terminal, nothing runs" "pass --yes" acme/tool v1.3.0
fixture; refused "a repo not in repos.yaml is refused" "isn't in repos.yaml" acme/other v1.3.0 --yes
fixture; refused "a tag that isn't semver is refused" "isn't a semver tag" acme/tool 1.3.0 --yes
fixture; refused "an existing tag is refused" "already has v1.1.0" acme/tool v1.1.0 --yes
fixture; refused "an older tag is refused" "v1.1.5 isn't newer than v1.2.0" acme/tool v1.1.5 --yes
fixture; echo 0 > "$t/fix/ahead"
refused "no commits since the latest tag is refused" "no commits since v1.2.0" acme/tool v1.3.0 --yes
fixture; printf 'lint\ntest\n' > "$t/fix/failed"
refused "failed checks on HEAD are refused" "check runs failed on main (0123456789abcdef): lint,test" acme/tool v1.3.0 --yes
fixture; sed -i.bak 's/tag:/version:/' "$t/fix/workflows/release.yml"
refused "no workflow with a tag input is refused" "no workflow that calls ship with a tag input" acme/tool v1.3.0 --yes

fixture
if release acme/tool v1.3.0-rc.1 --yes && grep -q 'tag=v1.3.0-rc.1' "$t/fix/dispatched"; then
  ok "a prerelease tag dispatches"
else fail "a prerelease tag dispatches"; fi

if [ "$fails" -ne 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

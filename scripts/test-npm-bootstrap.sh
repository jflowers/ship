#!/usr/bin/env bash
# Runs npm-bootstrap.sh against a fixture repos.yaml, a fake gh (repos as
# fixture directories) and a fake npm (a list of published versions), and
# checks the plan and what --apply does.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
F=$t/fix
mkdir -p "$t/bin" "$F"
fails=0

ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; sed 's/^/     /' "$t/out"; fails=$((fails + 1)); }

# --- fixtures -------------------------------------------------------------
cat >"$t/repos.yaml" <<'EOF'
repos:
  acme/new: { kinds: [npm] }
  acme/done: { kinds: [npm] }
  acme/partial: { kinds: [npm] }
  acme/private: { kinds: [npm] }
  acme/nocaller: { kinds: [npm] }
  acme/build: { kinds: [npm] }
  acme/badurl: { kinds: [npm] }
  acme/tool: { kinds: [go] }
  org/staged: { kinds: [npm] }
  org/auto: { kinds: [npm] }
EOF

caller() { # <file> [with lines]
  cat <<EOF
on: workflow_dispatch
jobs:
  release:
    uses: jflowers/ship/.github/workflows/npm-release.yml@0123456789abcdef0123456789abcdef01234567 # v0.5.0
    with:
      tag: \${{ inputs.tag }}
${1:-}
EOF
}
repo() { # <owner/repo> <visibility> <owner type> <version> [package.json extra]
  local d=$F/$1
  mkdir -p "$d/workflows"
  echo "$2 main $3" >"$d/meta"
  printf '{"name": "%s", "version": "%s", "repository": {"url": "git+https://github.com/%s.git"}%s}\n' \
    "${1#*/}" "$4" "$1" "${5:-}" >"$d/package.json"
  caller >"$d/workflows/publish.yml"
  : >"$d/tags"
}
repo acme/new PUBLIC User 0.1.0
repo acme/done PUBLIC User 1.2.0
echo v1.2.0 >"$F/acme/done/tags"
repo acme/partial PUBLIC User 0.1.0
repo acme/private PRIVATE User 0.1.0
repo acme/nocaller PUBLIC User 0.1.0
echo 'jobs: { test: { runs-on: ubuntu-latest, steps: [{ run: "true" }] } }' >"$F/acme/nocaller/workflows/publish.yml"
repo acme/build PUBLIC User 0.1.0 ', "scripts": {"prepare": "tsc"}'
repo acme/badurl PUBLIC User 0.1.0
sed -i.bak 's#acme/badurl#acme/other#' "$F/acme/badurl/package.json"
repo org/staged PUBLIC Organization 0.3.0
rm "$F/org/staged/workflows/publish.yml"
echo 'name: CI' >"$F/org/staged/workflows/ci.yml"
caller '      stage: "true"
      environment: npm' >"$F/org/staged/workflows/release.yml"
repo org/auto PUBLIC Organization 0.2.0

printf '%s\n' 'done' 'done@1.2.0' partial partial@0.1.0 >"$F/npm-published"

# --- fakes ----------------------------------------------------------------
cat >"$t/bin/gh" <<'EOF'
#!/usr/bin/env bash
log() { echo "gh $*" >>"$LOG"; }
case "$1 $2" in
  "repo view") cat "$F/$3/meta" ;;
  "repo clone")
    mkdir -p "$4"; cp "$F/$3/package.json" "$4/"; log "repo clone $3" ;;
  "workflow run") log "$*" ;;
  api*)
    [ "$2" = -H ] && shift 2
    p=${2%%\?*}
    case $p in
      repos/*/*/contents/.github/workflows)
        r=${p#repos/}; r=${r%/contents/*}; ls "$F/$r/workflows" ;;
      repos/*/*/contents/.github/workflows/*)
        r=${p#repos/}; r=${r%/contents/*}; cat "$F/$r/workflows/${p##*/}" ;;
      repos/*/*/contents/package.json)
        r=${p#repos/}; r=${r%/contents/*}; cat "$F/$r/package.json" ;;
      repos/*/*/git/ref/tags/*)
        r=${p#repos/}; r=${r%/git/*}; grep -qxF "${p##*/}" "$F/$r/tags" ;;
      *) exit 2 ;;
    esac ;;
  *) exit 2 ;;
esac
EOF
cat >"$t/bin/npm" <<'EOF'
#!/usr/bin/env bash
log() { echo "npm $*" >>"$LOG"; }
case $1 in
  view) grep -qxF "$2" "$F/npm-published" ;;
  publish)
    n=$(yq -r .name package.json); v=$(yq -r .version package.json)
    log "publish $n@$v ${*:2}"; printf '%s\n' "$n" "$n@$v" >>"$F/npm-published" ;;
  stage) log "stage ${*:2} ($(yq -r .name package.json))" ;;
  trust)
    case $2 in
      list) cat "$F/trust-$3" 2>/dev/null ;;
      github) log "$*" ;;
    esac ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$t/bin/gh" "$t/bin/npm"

run() { # [args]: output in $t/out, calls in $t/log
  : >"$t/log"
  PATH="$t/bin:$PATH" F=$F LOG=$t/log SHIP_REPOS=$t/repos.yaml SHIP_NPM=$t/bin/npm \
    SHIP_POLL_SECONDS=0 SHIP_POLLS=2 "$here/npm-bootstrap.sh" "$@" >"$t/out" 2>&1
}
has() { grep -qF -- "$1" "$2"; }

# --- plan -----------------------------------------------------------------
cp "$F/npm-published" "$t/published.orig"
if run && [ ! -s "$t/log" ]; then ok "plan: changes nothing"; else fail "plan: changes nothing"; fi
for want in \
  "ready acme/new: publish new@0.1.0, trust publish.yml, dispatch v0.1.0" \
  "ready acme/partial: partial@0.1.0 is on npm with no tag: trust publish.yml, dispatch v0.1.0" \
  "skip  acme/private: private: the repo is private" \
  "skip  acme/nocaller: nocaller: no workflow on main calls ship's npm-release.yml" \
  "skip  acme/build: build: it builds at publish time" \
  "skip  acme/badurl: badurl: package.json repository.url is 'git+https://github.com/acme/other.git'" \
  "ready org/staged: stage staged@0.3.0, trust release.yml (environment npm), dispatch v0.3.0" \
  "ready org/auto: stage auto@0.2.0, trust publish.yml, dispatch v0.2.0" \
  "4 ready, 4 skipped"; do
  if has "$want" "$t/out"; then ok "plan: $want"; else fail "plan: $want"; fi
done
if ! grep -q 'acme/done\|acme/tool' "$t/out"; then ok "plan: published and non-npm repos are left out"; else fail "plan: published and non-npm repos are left out"; fi
if run acme/new && has "1 ready, 0 skipped" "$t/out"; then ok "plan: a repo target narrows it"; else fail "plan: a repo target narrows it"; fi
if run org && has "2 ready, 0 skipped" "$t/out"; then ok "plan: an owner target narrows it"; else fail "plan: an owner target narrows it"; fi

# --- apply ----------------------------------------------------------------
run --apply acme/new || true
expect_log() { # <name> <lines...>
  local name=$1 l; shift
  for l in "$@"; do has "$l" "$t/log" || { fail "apply: $name (missing: $l)"; cat "$t/log" | sed 's/^/     log: /'; return; }; done
  ok "apply: $name"
}
expect_log "publishes, trusts, dispatches" \
  "gh repo clone acme/new" \
  "npm publish new@0.1.0 --access public --ignore-scripts" \
  "npm trust github new --repo acme/new --file publish.yml -y --allow-publish" \
  "gh workflow run publish.yml -R acme/new --ref main -f tag=v0.1.0"
if [ "$(grep -n 'publish new@' "$t/log" | cut -d: -f1)" -lt "$(grep -n 'trust github new' "$t/log" | cut -d: -f1)" ] &&
  [ "$(grep -n 'trust github new' "$t/log" | cut -d: -f1)" -lt "$(grep -n 'workflow run' "$t/log" | cut -d: -f1)" ]; then
  ok "apply: in that order"
else fail "apply: in that order"; fi

cp "$t/published.orig" "$F/npm-published"
run --apply acme/partial || true
expect_log "resumes with trust and dispatch" \
  "npm trust github partial --repo acme/partial --file publish.yml -y --allow-publish" \
  "gh workflow run publish.yml -R acme/partial --ref main -f tag=v0.1.0"
if ! has "publish partial" "$t/log" && ! has "repo clone" "$t/log"; then ok "apply: resume doesn't publish again"; else fail "apply: resume doesn't publish again"; fi

echo publish.yml >"$F/trust-partial"
run --apply acme/partial || true
if ! has "trust github" "$t/log" && has "workflow run" "$t/log"; then ok "apply: an existing trusted publisher is kept"; else fail "apply: an existing trusted publisher is kept"; fi

run --apply org/staged || true
expect_log "stages an organization's package and stops for approval" \
  "npm stage publish --access public --ignore-scripts (staged)"
if ! has "trust github" "$t/log" && ! has "workflow run" "$t/log" && has "approve staged@0.3.0" "$t/out"; then
  ok "apply: nothing after staging until it's approved"
else fail "apply: nothing after staging until it's approved"; fi
printf '%s\n' staged staged@0.3.0 >>"$F/npm-published"
run --apply org/staged || true
expect_log "after approval: trusts staging only, with the environment" \
  "npm trust github staged --repo org/staged --file release.yml -y --env npm --allow-stage-publish" \
  "gh workflow run release.yml -R org/staged --ref main -f tag=v0.3.0"

# The registry never shows it: stop before trust and dispatch. Lookups use
# the npm on PATH, so the slow one goes first there.
mkdir -p "$t/slow"
cat >"$t/slow/npm" <<EOF
#!/usr/bin/env bash
[ "\$1" = view ] && [ "\${2#*@}" != "\$2" ] && exit 1
exec "$t/bin/npm" "\$@"
EOF
chmod +x "$t/slow/npm"
cp "$t/published.orig" "$F/npm-published"
: >"$t/log"
if ! PATH="$t/slow:$t/bin:$PATH" F=$F LOG=$t/log SHIP_REPOS=$t/repos.yaml SHIP_NPM=$t/bin/npm \
  SHIP_POLL_SECONDS=0 SHIP_POLLS=2 "$here/npm-bootstrap.sh" --apply acme/new >"$t/out" 2>&1 &&
  has "still isn't on the registry" "$t/out" && ! has "trust github" "$t/log" && ! has "workflow run" "$t/log"; then
  ok "apply: no dispatch until the registry serves the version"
else fail "apply: no dispatch until the registry serves the version"; fi

if [ "$fails" -ne 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

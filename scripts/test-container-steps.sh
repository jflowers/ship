#!/usr/bin/env bash
# Runs container-image.yml's settings check (extracted with yq, so the
# workflow stays the only copy). Runs anywhere; building and pushing need
# podman and a registry, so they're proven by a caller's runs.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
wf=$here/../.github/workflows/container-image.yml
settings=$(yq '.jobs.settings.steps[] | select(.id == "s") | .run' "$wf")
[ -n "$settings" ] || { echo "no settings step in $wf"; exit 1; }

fails=0
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; sed 's/^/     /' "$t/err" 2>/dev/null || true; fails=$((fails + 1)); }

# run <image> <tags> <push> [names of unset secrets]; outputs in $t/out
run() {
  : > "$t/out"
  local user=true pass=true
  [[ " ${4:-} " == *" REGISTRY_USERNAME "* ]] && user=false
  [[ " ${4:-} " == *" REGISTRY_PASSWORD "* ]] && pass=false
  IMAGE=$1 TAGS=$2 PUSH=$3 HAS_REGISTRY_USERNAME=$user HAS_REGISTRY_PASSWORD=$pass \
    GITHUB_OUTPUT="$t/out" bash -c "$settings" > "$t/err" 2>&1
}
expect() { # <pass|fail> <name> <image> <tags> <push> [unset] -- [output lines]
  local want=$1 name=$2 got line
  shift 2
  local args=() lines=()
  while (($#)) && [ "$1" != -- ]; do args+=("$1"); shift; done
  (($#)) && shift && lines=("$@")
  if run "${args[@]}"; then got=pass; else got=fail; fi
  if [ "$got" != "$want" ]; then fail "settings: $name (got $got)"; return; fi
  for line in "${lines[@]+"${lines[@]}"}"; do
    grep -qxF "$line" "$t/out" || { fail "settings: $name (no '$line'; got: $(tr '\n' ' ' < "$t/out"))"; return; }
  done
  ok "settings: $name"
}

expect pass "quay.io image, latest" quay.io/unbound-force/opencode-dev latest true -- \
  registry=quay.io name=opencode-dev "tags=latest"
expect pass "several tags, spaces and newlines" quay.io/org/x "v1.2.3
latest  stable" true -- "tags=v1.2.3 latest stable"
expect pass "a registry with a port" registry.example.com:5000/team/app latest false -- \
  registry=registry.example.com:5000 name=app
expect pass "localhost" localhost/app latest false -- registry=localhost
expect pass "no push needs no credentials" quay.io/org/x latest false "REGISTRY_USERNAME REGISTRY_PASSWORD"
expect fail "push without a password" quay.io/org/x latest true REGISTRY_PASSWORD
expect fail "push without either credential" quay.io/org/x latest true "REGISTRY_USERNAME REGISTRY_PASSWORD"
expect fail "an image with a tag" quay.io/org/x:latest latest false
expect fail "an image with a digest" quay.io/org/x@sha256:abc latest false
expect fail "no registry host" org/x latest false
expect fail "a bare name" x latest false
expect fail "uppercase" quay.io/Org/x latest false
expect fail "no tags" quay.io/org/x "  " false
expect fail "a tag with a slash" quay.io/org/x "feature/x" false
expect fail "a tag starting with a dot" quay.io/org/x ".hidden" false
if run quay.io/org/x latest true "REGISTRY_USERNAME REGISTRY_PASSWORD" ||
  ! grep -q "REGISTRY_USERNAME REGISTRY_PASSWORD wasn't passed" "$t/err"; then
  fail "settings: the error names the missing credentials"
else ok "settings: the error names the missing credentials"; fi

if [ "$fails" -ne 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

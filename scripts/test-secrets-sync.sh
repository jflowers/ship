#!/usr/bin/env bash
# Runs secrets-sync.sh against testdata/secrets-repos.yaml with a fake HOME
# (the env files) and a fake gh on PATH that records what it's asked to do.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
sync=$here/secrets-sync.sh
fails=0
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; sed 's/^/     /' "$t/out" "$t/gh.log" 2>/dev/null; fails=$((fails + 1)); }

mkdir -p "$t/bin" "$t/home/.config" "$t/have"
# Fake gh. Existing secrets: $t/have/<owner_repo or org>, one name a line;
# a missing org file means the token can't list org secrets.
cat >"$t/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "secret list")
    f=$FAKE/have/${4//\//_}
    if [[ $3 == --org && ! -f $f ]]; then echo "HTTP 403" >&2; exit 1; fi
    cat "$f" 2>/dev/null || true ;;
  "secret set") shift 2; echo "set $* <$(cat)>" >>"$FAKE/gh.log" ;;
  "secret delete") shift 2; echo "delete $*" >>"$FAKE/gh.log" ;;
  *) echo "fake gh: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$t/bin/gh"
cat >"$t/home/.config/apple-developer" <<'EOF'
MACOS_SIGN_P12='p12-value'
MACOS_SIGN_PASSWORD='pw-value'
HOMEBREW_TAP_TOKEN='personal-tap'
EMPTY_ONE=''
EOF
printf 'MACOS_SIGN_P12\nMACOS_SIGN_PASSWORD\nHOMEBREW_TAP_TOKEN\nHOMEBREW_TAP_GITHUB_TOKEN\n' >"$t/have/acme_one"
printf 'MACOS_SIGN_P12\n' >"$t/have/me_app"

run() { # args...; output in $t/out, gh calls in $t/gh.log
  rm -f "$t/gh.log"
  touch "$t/gh.log"
  HOME=$t/home FAKE=$t PATH=$t/bin:$PATH SHIP_REPOS=${CONFIG:-$here/testdata/secrets-repos.yaml} \
    "$sync" "$@" >"$t/out" 2>&1
}

# 1. The plan sets nothing and shows both kinds of target.
if run && [[ ! -s $t/gh.log ]] &&
  grep -q '^acme (org secrets)$' "$t/out" &&
  grep -q 'set     MACOS_SIGN_P12 (can.t list) for acme/one, acme/two' "$t/out" &&
  grep -q 'repo copies override it in acme/one (--prune deletes them)' "$t/out" &&
  grep -q '^me/app$' "$t/out" && grep -q 'set     MACOS_SIGN_P12 (replace)' "$t/out" &&
  grep -q 'set     HOMEBREW_TAP_TOKEN (new)' "$t/out" &&
  ! grep -q 'me/lib' "$t/out"; then
  ok "plan touches nothing, lists org and repo secrets, skips repos without secrets"
else fail "plan touches nothing, lists org and repo secrets, skips repos without secrets"; fi

# 2. A missing value is reported by name and file, never set.
if grep -q 'skip    HOMEBREW_TAP_TOKEN: ACME_TAP is empty or missing in .*/apple-developer' "$t/out" &&
  grep -q 'skip    MACOS_NOTARY_KEY: EMPTY_ONE is empty' "$t/out"; then
  ok "missing and empty values are skipped with the reason"
else fail "missing and empty values are skipped with the reason"; fi

# 3. --apply: org secrets go to the org with the repos selected (bare names),
# repo secrets to the repo, values on stdin; skips make it exit 1.
if ! run --apply &&
  grep -qx 'set MACOS_SIGN_P12 --org acme --visibility selected --repos one,two <p12-value>' "$t/gh.log" &&
  grep -qx 'set MACOS_SIGN_PASSWORD --repo me/app <pw-value>' "$t/gh.log" &&
  grep -qx 'set HOMEBREW_TAP_TOKEN --repo me/app <personal-tap>' "$t/gh.log" &&
  ! grep -q 'HOMEBREW_TAP_TOKEN --org' "$t/gh.log" && ! grep -q '^delete' "$t/gh.log" &&
  grep -q 'skipped 3' "$t/out"; then
  ok "--apply sets org and repo secrets from the env file and fails on skips"
else fail "--apply sets org and repo secrets from the env file and fails on skips"; fi

# 4. --prune deletes only repo copies of org secrets it just set.
if ! run --apply --prune &&
  grep -qx 'delete MACOS_SIGN_P12 --repo acme/one' "$t/gh.log" &&
  grep -qx 'delete MACOS_SIGN_PASSWORD --repo acme/one' "$t/gh.log" &&
  [[ $(grep -c '^delete' "$t/gh.log") -eq 2 ]]; then
  ok "--prune deletes only the repo copies an org secret replaced"
else fail "--prune deletes only the repo copies an org secret replaced"; fi

# 5. Targets narrow the run to an owner or a repo.
if ! run --apply me/app && ! grep -q -- '--org' "$t/gh.log" && grep -q -- '--repo me/app' "$t/gh.log" &&
  ! grep -q '^acme' "$t/out"; then
  ok "a repo target syncs only that repo"
else fail "a repo target syncs only that repo"; fi
if run acme/two && grep -q '^acme (org secrets)$' "$t/out" && ! grep -q '^me/app' "$t/out"; then
  ok "a repo target includes the org secrets that reach it"
else fail "a repo target includes the org secrets that reach it"; fi

# 6. An org that's listable shows new/replace instead of "can't list".
printf 'MACOS_SIGN_P12\n' >"$t/have/acme"
if run && grep -q 'set     MACOS_SIGN_P12 (replace) for' "$t/out" &&
  grep -q 'set     MACOS_SIGN_PASSWORD (new) for' "$t/out"; then
  ok "org secrets are compared when gh can list them"
else fail "org secrets are compared when gh can list them"; fi

# 7. Config errors: one org secret wanted from two sources, unknown set,
# --prune without --apply.
yq '.repos["acme/two"].tap = "me/tap"' "$here/testdata/secrets-repos.yaml" >"$t/conflict.yaml"
if ! CONFIG=$t/conflict.yaml run && grep -q 'acme gets HOMEBREW_TAP_TOKEN from both' "$t/out" && [[ ! -s $t/gh.log ]]; then
  ok "repos in one org needing different values for one secret is an error"
else fail "repos in one org needing different values for one secret is an error"; fi
yq '.repos["me/app"].secrets += ["nope"]' "$here/testdata/secrets-repos.yaml" >"$t/unknown.yaml"
if ! CONFIG=$t/unknown.yaml run && grep -q 'unknown secret sets: nope' "$t/out"; then
  ok "an unknown secret set is an error"
else fail "an unknown secret set is an error"; fi
if ! run --prune && grep -q -- '--prune needs --apply' "$t/out"; then
  ok "--prune needs --apply"
else fail "--prune needs --apply"; fi

if [ "$fails" -ne 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

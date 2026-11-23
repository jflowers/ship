#!/usr/bin/env bash
# Runs go-release.yml's shell steps (extracted with yq, so the workflow
# stays the only copy): the checksum rewrite and cask patch, against a real
# GoReleaser 2.15 cask in testdata/, and the tap push retry, against a local
# bare repo. Runs anywhere; the brew audit is test-audit-cask.sh (macOS).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
wf=$here/../.github/workflows/go-release.yml
step=$(yq '.jobs.publish-cask.steps[] | select(.id == "patch") | .run' "$wf")
[ -n "$step" ] || { echo "no patch step in $wf"; exit 1; }

fails=0
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

run() { (cd "$t" && CASK_FILE=cask.rb CHECKSUMS=checksums.txt bash -c "$step") 2> "$t/err"; }
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; sed 's/^/     /' "$t/err" 2>/dev/null || true; fails=$((fails + 1)); }

fresh() {
  cp "$here/testdata/cask.rb" "$t/cask.rb"
  cp "$here/testdata/checksums.txt" "$t/checksums.txt"
}

# 1. Signed darwin archives: their new sums replace the old, linux untouched.
fresh
sed -i.bak -E 's/^[0-9a-f]{64}(  .*_darwin_amd64\.tar\.gz)$/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\1/;
               s/^[0-9a-f]{64}(  .*_darwin_arm64\.tar\.gz)$/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\1/' "$t/checksums.txt"
if run &&
  grep -B1 'darwin_amd64' "$t/cask.rb" | grep -q 'sha256 "a\{64\}"' &&
  grep -B1 'darwin_arm64' "$t/cask.rb" | grep -q 'sha256 "b\{64\}"' &&
  grep -q 'sha256 "35d5e02a58d7756476aaaf22dcb12571f89ba8e0571e6e02d49b6c91d00da9ba"' "$t/cask.rb" &&
  [ "$(diff "$here/testdata/cask.rb" "$t/cask.rb" | grep -c '^>')" -eq 2 ]; then
  ok "signed sums replace unsigned, others untouched"
else fail "signed sums replace unsigned, others untouched"; fi

# 2. Unsigned release: the cask already matches, so nothing changes.
fresh
if run && diff -q "$here/testdata/cask.rb" "$t/cask.rb" >/dev/null; then
  ok "unchanged when sums already match"
else fail "unchanged when sums already match"; fi

# 3. Idempotent: patching twice gives the same file.
fresh
sed -i.bak -E 's/^[0-9a-f]{64}(  .*_darwin_arm64\.tar\.gz)$/cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\1/' "$t/checksums.txt"
run && cp "$t/cask.rb" "$t/once.rb"
if run && diff -q "$t/once.rb" "$t/cask.rb" >/dev/null; then
  ok "idempotent"
else fail "idempotent"; fi

# 4. sha256 after url (the other layout GoReleaser has used) also works.
fresh
awk '/^[[:space:]]*sha256 /{ held = $0; next } { print } /^[[:space:]]*url /{ print held }' \
  "$here/testdata/cask.rb" > "$t/cask.rb"
sed -i.bak -E 's/^[0-9a-f]{64}(  .*_darwin_arm64\.tar\.gz)$/dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\1/' "$t/checksums.txt"
if run && grep -A1 'darwin_arm64' "$t/cask.rb" | grep -q 'sha256 "d\{64\}"'; then
  ok "sha256 after url"
else fail "sha256 after url"; fi

# 5. An archive missing from checksums.txt fails instead of shipping a stale sum.
fresh
grep -v darwin_amd64 "$here/testdata/checksums.txt" > "$t/checksums.txt"
if ! run && grep -q '_darwin_amd64.tar.gz' "$t/err"; then
  ok "missing checksum fails"
else fail "missing checksum fails"; fi

# 6. A url with no sha256 beside it fails.
fresh
awk '/darwin_arm64/{ print "      # moved"; } { print }' "$here/testdata/cask.rb" > "$t/cask.rb"
if ! run && grep -q 'no sha256 next to' "$t/err"; then
  ok "url without sha256 fails"
else fail "url without sha256 fails"; fi

# --- sign-macos "checksums" step ---
csum=$(yq '.jobs.sign-macos.steps[] | select(.id == "checksums") | .run' "$wf")
runsum() { (cd "$t" && SIGNED=out IN=in.txt OUT=out.txt bash -c "$csum") > "$t/err" 2>&1; }

# 7. Signed archives' lines are rewritten in place, format kept.
rm -rf "${t:?}"/*; mkdir -p "$t/out"
cp "$here/testdata/checksums.txt" "$t/in.txt"
for a in darwin_amd64 darwin_arm64; do echo "signed $a" > "$t/out/replicator_0.5.4-rc2-SNAPSHOT-d59a3e8_$a.tar.gz"; done
if runsum && (cd "$t/out" && cp ../out.txt . && grep darwin out.txt | shasum -a 256 -c - >/dev/null) &&
  [ "$(grep -c linux "$t/out.txt")" -eq 2 ] && diff <(awk '{print $2}' "$t/in.txt") <(awk '{print $2}' "$t/out.txt") >/dev/null &&
  ! grep -qv '^[0-9a-f]\{64\}  ' "$t/out.txt"; then
  ok "checksums.txt rewritten in place"
else fail "checksums.txt rewritten in place"; fi

# 8. A signed archive that checksums.txt doesn't list fails.
echo extra > "$t/out/replicator_9_darwin_arm64.tar.gz"
if ! runsum && grep -q "doesn't list every signed archive" "$t/err"; then
  ok "unlisted signed archive fails"
else fail "unlisted signed archive fails"; fi

# --- publish-cask "push" step ---
push=$(yq '.jobs.publish-cask.steps[] | select(.name == "Push to the tap") | .run' "$wf")
gitc() { git -c user.name=test -c user.email=test@example.com "$@"; }

# 9. Another repo pushed to the tap first: rebase and push, keeping both.
rm -rf "${t:?}"/*
git init -q --bare -b main "$t/origin.git"
gitc clone -q "$t/origin.git" "$t/seed" 2>/dev/null
mkdir -p "$t/seed/Casks" && echo a > "$t/seed/Casks/dewey.rb" && gitc -C "$t/seed" add -A && gitc -C "$t/seed" commit -qm seed && git -C "$t/seed" push -q origin main
git clone -q --depth 1 "file://$t/origin.git" "$t/tap"
echo r > "$t/tap/Casks/replicator.rb" && gitc -C "$t/tap" add -A && gitc -C "$t/tap" commit -qm replicator
echo b > "$t/seed/Casks/dewey.rb" && gitc -C "$t/seed" commit -qam "dewey bump" && git -C "$t/seed" push -q origin main
if (cd "$t/tap" && GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com \
      TAP=local bash -c "sleep() { :; }; $push") > "$t/err" 2>&1 &&
  [ "$(git -C "$t/origin.git" show main:Casks/dewey.rb)" = b ] &&
  [ "$(git -C "$t/origin.git" show main:Casks/replicator.rb)" = r ] && grep -q 'attempt 1' "$t/err"; then
  ok "push rebases over a concurrent tap push"
else fail "push rebases over a concurrent tap push"; fi

# 10. Someone else changed the same cask: fail, don't overwrite.
gitc -C "$t/seed" pull -q --rebase origin main
echo other > "$t/seed/Casks/replicator.rb" && gitc -C "$t/seed" commit -qam "other replicator" && git -C "$t/seed" push -q origin main
echo mine > "$t/tap/Casks/replicator.rb" && gitc -C "$t/tap" commit -qam mine
if ! (cd "$t/tap" && GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com \
      TAP=local bash -c "sleep() { :; }; $push") > "$t/err" 2>&1 &&
  [ "$(git -C "$t/origin.git" show main:Casks/replicator.rb)" = other ]; then
  ok "conflicting cask change fails without overwriting"
else fail "conflicting cask change fails without overwriting"; fi

# --- settings: which signing secrets were passed ---------------------------
settings=$(yq '.jobs.settings.steps[] | select(.id == "s") | .run' "$wf")
signing="MACOS_SIGN_P12 MACOS_SIGN_PASSWORD MACOS_NOTARY_KEY MACOS_NOTARY_KEY_ID MACOS_NOTARY_ISSUER_ID"
# runset <names passed...>: runs the step with those HAS_* true; output in $t/out
runset() {
  local envs=(TAP="${TAP-}" REPO=gaze BINARY= PREFIX= CASK= GITHUB_OUTPUT="$t/out"
    HAS_HOMEBREW_TAP_TOKEN="${HAS_TOKEN:-true}")
  local n
  for n in $signing; do envs+=("HAS_$n=false"); done
  for n in "$@"; do envs+=("HAS_$n=true"); done
  : > "$t/out"
  env "${envs[@]}" bash -c "$settings" > "$t/err" 2>&1
}

# shellcheck disable=SC2086 # word-split on purpose
if runset $signing && grep -qx 'sign=true' "$t/out" && grep -qx 'cask=gaze' "$t/out"; then
  ok "all signing secrets: sign"
else fail "all signing secrets: sign"; fi
if runset && grep -qx 'sign=false' "$t/out" && grep -q 'ship unsigned' "$t/err"; then
  ok "no signing secrets: unsigned, with a notice"
else fail "no signing secrets: unsigned, with a notice"; fi
if ! runset MACOS_SIGN_P12 MACOS_SIGN_PASSWORD MACOS_NOTARY_KEY &&
  grep -q 'missing: MACOS_NOTARY_KEY_ID MACOS_NOTARY_ISSUER_ID\.' "$t/err" && [ ! -s "$t/out" ]; then
  ok "some signing secrets: fails, naming the missing ones"
else fail "some signing secrets: fails, naming the missing ones"; fi
if ! TAP=o/tap HAS_TOKEN=false runset && grep -q "HOMEBREW_TAP_TOKEN wasn't passed" "$t/err"; then
  ok "a tap without a token fails"
else fail "a tap without a token fails"; fi

if [ "$fails" -ne 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

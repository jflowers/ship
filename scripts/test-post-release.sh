#!/usr/bin/env bash
# Runs go-release.yml's post-release `go install` check (extracted with yq,
# so the workflow stays the only copy) against a fake `go` that installs a
# stub binary and reports build info. Runs anywhere; the brew install from a
# tap is in test-audit-cask.sh (macOS, CI only).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
wf=$here/../.github/workflows/go-release.yml
step=$(yq '.jobs.verify-go-install.steps[] | select(.id == "go-install") | .run' "$wf")
[ -n "$step" ] || { echo "no go-install step in $wf"; exit 1; }

fails=0
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; sed 's/^/     /' "$t/err" 2>/dev/null || true; fails=$((fails + 1)); }

# Fake go. `go install <pkg>@<tag>` fails while $t/failures holds a count
# above zero (one fewer each time), then installs $BINS (default: the
# package's last element) into GOBIN and logs the argument.
# `go version -m <bin>` prints build info naming $INFO_PATH at $INFO_VERSION.
cat > "$t/bin/go" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  install)
    echo "$2" >> "$LOG"
    n=$(cat "$FAILURES" 2>/dev/null || echo 0)
    if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$FAILURES"; echo "proxy: not found" >&2; exit 1; fi
    pkg=${2%@*}
    for b in ${BINS:-${pkg##*/}}; do printf '#!/bin/sh\n' > "$GOBIN/$b"; chmod +x "$GOBIN/$b"; done ;;
  version)
    [ "$2" = -m ] || exit 2
    printf '%s: go1.25.4\n\tpath\t%s\n\tmod\t%s\t%s\th1:abc=\n' "$3" "$INFO_PATH" "${INFO_PATH%/cmd/*}" "$INFO_VERSION" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$t/bin/go"

pkg=github.com/acme/tool/v2/cmd/tool
# run [failures]; env INFO_PATH/INFO_VERSION/BINS as set by the caller
run() {
  rm -rf "$t/gobin" "$t/cache" && : > "$t/log" && : > "$t/out"
  echo "${1:-0}" > "$t/failures"
  (PATH="$t/bin:$PATH" LOG="$t/log" FAILURES="$t/failures" GOBIN="$t/gobin" GOMODCACHE="$t/cache" \
    PKG=$pkg TAG=v2.3.0 GITHUB_OUTPUT="$t/out" RUNNER_TEMP="$t" \
    INFO_PATH=${INFO_PATH:-$pkg} INFO_VERSION=${INFO_VERSION:-v2.3.0} \
    bash -c "sleep() { :; }; $step") > "$t/err" 2>&1
}

if run && grep -qxF "bin=$t/gobin/tool" "$t/out" && grep -qxF "$pkg@v2.3.0" "$t/log"; then
  ok "installs the tag and outputs the binary"
else fail "installs the tag and outputs the binary"; fi

if run 3 && [ "$(wc -l < "$t/log")" -eq 4 ] && grep -c 'attempt' "$t/err" | grep -qx 3; then
  ok "retries while the proxy lags"
else fail "retries while the proxy lags"; fi

if ! run 5 && [ "$(wc -l < "$t/log")" -eq 5 ] && grep -q 'failed after 5 attempts' "$t/err"; then
  ok "five failed installs fail"
else fail "five failed installs fail"; fi

if ! INFO_VERSION=v2.2.9 run && grep -q "the installed module is 'v2.2.9', not v2.3.0" "$t/err"; then
  ok "another version fails"
else fail "another version fails"; fi

if ! INFO_PATH=github.com/evil/tool/cmd/tool run && grep -q "built from 'github.com/evil/tool/cmd/tool'" "$t/err"; then
  ok "another package fails"
else fail "another package fails"; fi

if ! BINS="tool extra" run && grep -q 'expected one binary' "$t/err"; then
  ok "more than one binary fails"
else fail "more than one binary fails"; fi

# A /vN module installs a binary named for the command, not the version.
if BINS=dewey run && grep -qxF "bin=$t/gobin/dewey" "$t/out"; then
  ok "the binary is whatever go install wrote"
else fail "the binary is whatever go install wrote"; fi

if [ "$fails" -ne 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"

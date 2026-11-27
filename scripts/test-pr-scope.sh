#!/usr/bin/env bash
# Runs pr-scope.yml's detect step (read out with yq, so the workflow stays
# the only copy) against a fake git that answers `rev-parse` with the merge
# commit's second parent and `diff --raw` with fixture lines.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
wf=$here/../.github/workflows/pr-scope.yml
step=$(yq '.jobs.scope.steps[] | select(.id == "detect") | .run' "$wf")
[ -n "$step" ] || { echo "no detect step in $wf"; exit 1; }

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/bin"
fails=0

cat >"$t/bin/git" <<'EOF'
#!/usr/bin/env bash
case $1 in
  rev-parse) [ -n "$FAKE_PARENT" ] && echo "$FAKE_PARENT" ;;
  diff) printf '%s' "$FAKE_DIFF" ;;
  *) echo "fake git: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$t/bin/git"

z=0000000 a=1111111 b=2222222 tab=$'\t'
add() { printf ':000000 100644 %s %s A\t%s\n' "$z" "$a" "$1"; }
mod() { printf ':100644 100644 %s %s M\t%s\n' "$a" "$b" "$1"; }
del() { printf ':100644 000000 %s %s D\t%s\n' "$a" "$z" "$1"; }
L=.uf/dewey/learnings

# check NAME WANT(code/scope, or "error") DIFF [VAR=value...]
check() {
  local name=$1 want=$2 diff=$3 got status=0
  shift 3
  : >"$t/out"
  env -i PATH="$t/bin:/usr/bin:/bin" GITHUB_OUTPUT="$t/out" \
    EVENT_NAME=pull_request HEAD_SHA=head FAKE_PARENT=head \
    HEAD_REF=chore/toolkit-uf-0.23.0 AUTHOR=jflowers \
    LEARNINGS_DIR=$L/ TOOLKIT_PATHS=.opencode/ TOOLKIT_AUTHOR=jflowers \
    FAKE_DIFF="$diff" "$@" bash -c "$step" >"$t/log" 2>&1 || status=$?
  if [ "$status" != 0 ]; then
    got=error
  else
    got=$(sed -n 's/^code=//p' "$t/out")/$(sed -n 's/^scope=//p' "$t/out")
  fi
  if [ "$got" = "$want" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: want $want, got $got"
    sed 's/^/     /' "$t/log"
    fails=$((fails + 1))
  fi
}

# Learnings, from any author or branch.
check "added learning" false/learnings "$(add $L/a.md)" HEAD_REF=chore/dewey-learnings-x AUTHOR=someone
check "edited and deleted learnings" false/learnings "$(mod $L/a.md; del $L/b.md)"
check "learning, no trailing newline" false/learnings "$(add $L/a.md | tr -d '\n')"
check "non-markdown in learnings" true/full "$(add $L/a.txt)" HEAD_REF=feat/x
check "markdown look-alike" true/full "$(add $L/a.md.go)" HEAD_REF=feat/x
check "bare .md" true/full "$(add $L/.md)" HEAD_REF=feat/x
check "look-alike directory" true/full "$(add .uf/dewey/learnings-old/a.md)" HEAD_REF=feat/x
check "learning plus code" true/full "$(add $L/a.md; mod go.mod)"
check "learnings off" true/full "$(add $L/a.md)" LEARNINGS_DIR= HEAD_REF=feat/x

# Toolkit rollouts.
check "toolkit scaffold" false/toolkit "$(mod .opencode/commands/uf.review-pr.md; add .opencode/lib/x.ts; del .opencode/skills/old/SKILL.md)"
check "toolkit, nested dir" false/toolkit "$(add .opencode/uf/packs/meta-prompt.md)"
check "toolkit, several paths" false/toolkit "$(add .opencode/a.md; mod .uf/config.yaml)" TOOLKIT_PATHS=".opencode/ .uf/"
check "toolkit touches code" true/full "$(mod .opencode/a.md; mod main.go)"
check "toolkit touches workflow" true/full "$(mod .github/workflows/ci.yml)"
check "toolkit, someone else" true/full "$(mod .opencode/a.md)" AUTHOR=mallory
check "toolkit, other branch" true/full "$(mod .opencode/a.md)" HEAD_REF=feat/opencode
check "toolkit, bare prefix branch" true/full "$(mod .opencode/a.md)" HEAD_REF=chore/toolkit-
check "toolkit off" true/full "$(mod .opencode/a.md)" TOOLKIT_PATHS=
check "toolkit look-alike dir" true/full "$(mod .opencode-old/a.md)"
check "toolkit dir itself" true/full "$(add .opencode/)"
check "toolkit plus learning" true/full "$(mod .opencode/a.md; add $L/a.md)"

# Fail closed.
check "push" true/full "" EVENT_NAME=push
check "no files" true/full ""
check "symlink" true/full ":000000 120000 $z $a A${tab}.opencode/link"
check "submodule" true/full ":000000 160000 $z $a A${tab}.opencode/sub"
check "dot-dot" true/full "$(add .opencode/../main.go)"
check "dot segment" true/full "$(add .opencode/./a.md)"
check "quoted path" true/full "$(add '".opencode/\303\251.md"')"
check "garbage line" true/full "not a diff line"
check "not the merge commit" error "$(mod .opencode/a.md)" FAKE_PARENT=
check "merge parent is not head" error "$(mod .opencode/a.md)" FAKE_PARENT=other
check "absolute prefix" error "$(mod .opencode/a.md)" TOOLKIT_PATHS=/etc/
check "no trailing slash" error "$(mod .opencode/a.md)" TOOLKIT_PATHS=.opencode
check "dot-dot prefix" error "$(mod .opencode/a.md)" LEARNINGS_DIR=../x/

if [ "$fails" -gt 0 ]; then
  echo "$fails failed"
  exit 1
fi

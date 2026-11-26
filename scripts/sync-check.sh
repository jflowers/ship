#!/usr/bin/env bash
# Checks each repo in repos.yaml against its own workflows: that it calls
# the ship workflows repos.yaml lists, which ship tag its pin is, and that
# it passes what its entry implies (the tap, the signing secrets, the
# post-release checks). Prints a Markdown report; exits 1 if any repo has a
# problem. Reads only.
#
#   scripts/sync-check.sh                 fetch each repo's workflows with gh
#   scripts/sync-check.sh --dir <dir>     read <dir>/<owner>/<repo>/*.yml
#                                         instead (tests), with ship's tags
#                                         from <dir>/tags (<sha> <tag> lines)
#
# A warning (a check the repo could add) is reported but doesn't fail.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repos_yaml=${REPOS_YAML:-$here/../repos.yaml}
dir=""
if [ "${1:-}" = --dir ]; then dir=$2; fi

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT

# ship's tags, <sha> <tag>, newest first.
if [ -n "$dir" ]; then
  cp "$dir/tags" "$t/tags"
else
  gh api 'repos/jflowers/ship/tags?per_page=100' --paginate -q '.[] | "\(.commit.sha) \(.name)"' > "$t/tags"
fi
latest=$(awk '{print $2}' "$t/tags" | sort -V | tail -1)

# workflows <repo>: a directory holding the repo's .github/workflows/*.yml
workflows() {
  if [ -n "$dir" ]; then echo "$dir/$1"; return; fi
  d=$t/wf/$1
  mkdir -p "$d"
  gh api "repos/$1/contents/.github/workflows" -q '.[] | select(.name | test("\\.ya?ml$")) | .name' 2>/dev/null |
    while read -r f; do
      gh api "repos/$1/contents/.github/workflows/$f" -q .content | base64 -d > "$d/$f"
    done
  echo "$d"
}

problems=0
echo "# Ship sync check"
echo
echo "Latest ship tag: \`$latest\`"
echo

for repo in $(yq '.repos | keys | .[]' "$repos_yaml"); do
  e=".repos[\"$repo\"]"
  wf=$(yq "$e.workflow // \"\"" "$repos_yaml")
  case "$wf" in "" | own* | none*) continue ;; esac

  issues=() warns=()
  d=$(workflows "$repo")
  # The ship workflows repos.yaml names, and the version it records.
  want=$(grep -oE '[a-z-]+-release\.yml|[a-z-]+-image\.yml' <<<"$wf" | sort -u)
  recorded=$(grep -oE '@v[0-9]+\.[0-9]+\.[0-9]+' <<<"$wf" | tr -d @ || true)
  # Every job, in every workflow file, that calls a ship workflow:
  # <file> <job> <workflow> <sha>
  : > "$t/calls"
  for f in "$d"/*.yml "$d"/*.yaml; do
    [ -f "$f" ] || continue
    yq -r '.jobs // {} | to_entries | .[] | select(.value.uses // "" | test("^jflowers/ship/\\.github/workflows/")) | .key + " " + .value.uses' "$f" |
      while read -r job uses; do
        w=${uses#jflowers/ship/.github/workflows/}
        echo "$f $job ${w%@*} ${w#*@}"
      done >> "$t/calls"
  done

  pins=""
  for w in $want; do
    if ! awk -v w="$w" '$3 == w' "$t/calls" | grep -q .; then
      issues+=("doesn't call \`$w\`")
      continue
    fi
    while read -r sha; do
      tag=$(awk -v s="$sha" '$1 == s {print $2}' "$t/tags" | head -1)
      if [ -z "$tag" ]; then
        issues+=("\`$w\` is pinned to \`${sha:0:12}\`, which is no ship tag")
        continue
      fi
      pins="$pins $tag"
      # Dependabot's ship group moves pins on its own, so repos.yaml lags.
      if [ -n "$recorded" ] && [ "$tag" != "$recorded" ]; then
        warns+=("\`$w\` is pinned to $tag; repos.yaml says $recorded")
      fi
      if [ "$tag" != "$latest" ]; then
        warns+=("\`$w\` is on $tag (latest is $latest)")
      fi
    done < <(awk -v w="$w" '$3 == w {print $4}' "$t/calls" | sort -u)
  done

  # with <workflow> <input>: the input's value in the first job calling it
  with() {
    read -r f job _ < <(awk -v w="$1" '$3 == w' "$t/calls") || return 0
    yq -r ".jobs[\"$job\"].with[\"$2\"] // \"\"" "$f"
  }
  secret() {
    read -r f job _ < <(awk -v w="$1" '$3 == w' "$t/calls") || return 0
    yq -r ".jobs[\"$job\"].secrets[\"$2\"] // \"\"" "$f"
  }

  tap=$(yq "$e.tap // \"\"" "$repos_yaml")
  kinds=$(yq "$e.kinds // [] | join(\" \")" "$repos_yaml")
  mise=$(yq "$e.mise // \"\"" "$repos_yaml")
  if grep -qx go-release.yml <<<"$want"; then
    if [ -n "$tap" ]; then
      got=$(with go-release.yml tap)
      [ "$got" = "$tap" ] || issues+=("go-release.yml's \`tap\` is '$got', not $tap")
      [ -n "$(secret go-release.yml HOMEBREW_TAP_TOKEN)" ] || issues+=("doesn't pass HOMEBREW_TAP_TOKEN")
      if [[ " $kinds " == *" cask "* ]] && [ -z "$(with go-release.yml tap_install_check)" ]; then
        warns+=("no \`tap_install_check\`")
      fi
    fi
    if [[ "$mise" == go:* ]]; then
      got=$(with go-release.yml go_install)
      if [ -z "$got" ]; then warns+=("no \`go_install\` (mise installs ${mise#go:})")
      elif [ "$got" != "${mise#go:}" ]; then issues+=("\`go_install\` is $got; mise installs ${mise#go:}"); fi
    fi
  fi
  # A secret set is used if its secrets are read anywhere in the repo's
  # workflows: passed to ship, or used in the caller's own jobs.
  for set in $(yq "$e.secrets // [] | .[]" "$repos_yaml"); do
    for name in $(yq ".secrets.sets[\"$set\"] | keys | .[]" "$repos_yaml"); do
      grep -qE "secrets\.$name([^A-Z0-9_]|$)" "$d"/*.y*ml 2>/dev/null || issues+=("doesn't use secret $name ($set)")
    done
  done

  pins=$(tr ' ' '\n' <<<"$pins" | grep . | sort -uV | paste -sd, - || true)
  if [ ${#issues[@]} -eq 0 ]; then
    echo "- ✅ **$repo** ($pins)"
  else
    problems=$((problems + 1))
    echo "- ❌ **$repo** (${pins:-no pin})"
    for i in "${issues[@]}"; do echo "  - $i"; done
  fi
  if [ ${#warns[@]} -ne 0 ]; then
    for w in "${warns[@]}"; do echo "  - ⚠️ $w"; done
  fi
done

echo
if [ "$problems" -ne 0 ]; then
  echo "$problems repo(s) out of sync."
  exit 1
fi
echo "All repos in sync."

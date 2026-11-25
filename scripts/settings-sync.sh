#!/usr/bin/env bash
# Sets every repo's GitHub settings as repos.yaml says: settings.defaults,
# then the repo's own `settings:` on top, and its `checks:`.
#
#   scripts/settings-sync.sh [--apply] [owner | owner/repo ...]
#
# Without --apply it only prints the plan. Settings:
#
#   vulnerability_alerts    Dependabot alerts; turning them on turns on the
#                           dependency graph (dependency-review-action
#                           needs it)
#   security_updates        Dependabot security update PRs (needs alerts)
#   allow_auto_merge, allow_rebase_merge, allow_squash_merge,
#   allow_merge_commit, delete_branch_on_merge
#                           the repo's own flags
#
# A repo's `checks:` are the status checks its default branch requires,
# kept in one ruleset, "ship: required checks", that repository admins
# bypass (so you can still push to it). deps-automerge.yml needs at least
# one required check, here or in branch protection. A repo without
# `checks:` keeps whatever it has. Owners in settings.skip are left alone:
# their own git-ops (safe-settings) owns their settings.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
config=${SHIP_REPOS:-$here/../repos.yaml}
ruleset_name="ship: required checks"
flags="allow_auto_merge allow_rebase_merge allow_squash_merge allow_merge_commit delete_branch_on_merge"
known="vulnerability_alerts security_updates $flags"

apply=0 targets=()
while (($#)); do
  case $1 in
    --apply) apply=1 ;;
    -h | --help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "settings-sync: unknown flag $1" >&2; exit 2 ;;
    *) targets+=("$1") ;;
  esac
  shift
done

unknown=$(yq -r '[.settings.defaults // {}, (.repos[].settings // {})] | .[] | keys | .[]' "$config" |
  sort -u | while read -r k; do case " $known " in *" $k "*) ;; *) echo "$k" ;; esac; done)
if [[ -n $unknown ]]; then
  echo "settings-sync: unknown settings: $unknown" >&2
  exit 1
fi

repos=$(yq -r '.repos | keys | .[]' "$config")
if ((${#targets[@]})); then
  repos=$(echo "$repos" | while read -r r; do
    for t in "${targets[@]}"; do
      if [[ $r == "$t" || ${r%%/*} == "$t" ]]; then echo "$r"; break; fi
    done
  done)
fi
[[ -n $repos ]] || { echo "settings-sync: no repos in repos.yaml match ${targets[*]}" >&2; exit 1; }

skip=" $(yq -r '.settings.skip // [] | join(" ")' "$config") "

changes=0
change() { # what; counts it and says so
  echo "  set     $1"
  changes=$((changes + 1))
}

for repo in $repos; do
  echo "$repo"
  if [[ $skip == *" ${repo%%/*} "* ]]; then
    echo "  --      skipped: ${repo%%/*} is in settings.skip (its own git-ops owns it)"
    continue
  fi
  want=$(r=$repo yq -o=json -I=0 '(.settings.defaults // {}) * (.repos[strenv(r)].settings // {})' "$config")
  info=$(gh api "repos/$repo")

  # Alerts before security updates: the second needs the first.
  w=$(jq -r 'select(has("vulnerability_alerts")) | .vulnerability_alerts' <<<"$want")
  if [[ -n $w ]]; then
    if gh api "repos/$repo/vulnerability-alerts" --silent 2>/dev/null; then h=true; else h=false; fi
    if [[ $h == "$w" ]]; then echo "  ok      vulnerability_alerts: $h"; else
      change "vulnerability_alerts: $h -> $w"
      if ((apply)); then
        if [[ $w == true ]]; then gh api -X PUT "repos/$repo/vulnerability-alerts" --silent
        else gh api -X DELETE "repos/$repo/vulnerability-alerts" --silent; fi
      fi
    fi
  fi
  w=$(jq -r 'select(has("security_updates")) | .security_updates' <<<"$want")
  if [[ -n $w ]]; then
    h=$(gh api "repos/$repo/automated-security-fixes" --jq .enabled 2>/dev/null || echo false)
    if [[ $h == "$w" ]]; then echo "  ok      security_updates: $h"; else
      change "security_updates: $h -> $w"
      if ((apply)); then
        if [[ $w == true ]]; then gh api -X PUT "repos/$repo/automated-security-fixes" --silent
        else gh api -X DELETE "repos/$repo/automated-security-fixes" --silent; fi
      fi
    fi
  fi

  patch=()
  for f in $flags; do
    w=$(jq -r --arg f "$f" 'select(has($f)) | .[$f]' <<<"$want")
    [[ -n $w ]] || continue
    h=$(jq -r --arg f "$f" '.[$f]' <<<"$info")
    if [[ $h == "$w" ]]; then echo "  ok      $f: $h"; else
      change "$f: $h -> $w"
      patch+=(-F "$f=$w")
    fi
  done
  if ((apply && ${#patch[@]})); then
    gh api -X PATCH "repos/$repo" "${patch[@]}" --silent
  fi

  # Required checks, in ship's ruleset.
  # A private repo on GitHub Free has no rulesets or branch protection.
  checks=$(r=$repo yq -o=json -I=0 '.repos[strenv(r)].checks // []' "$config")
  if ! rulesets=$(gh api "repos/$repo/rulesets" 2>/dev/null); then
    echo "  --      checks: rulesets unavailable (a private repo needs GitHub Pro); nothing can be required"
    continue
  fi
  if [[ $checks == "[]" ]]; then
    branch=$(jq -r .default_branch <<<"$info")
    now=$(gh api "repos/$repo/rules/branches/$branch" \
      --jq '[.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context] | join(", ")')
    classic=$(gh api "repos/$repo/branches/$branch" \
      --jq '.protection.required_status_checks.contexts // [] | join(", ")')
    echo "  --      checks: not in repos.yaml (rulesets: ${now:-none}; branch protection: ${classic:-none})"
    continue
  fi
  id=$(jq -r ".[] | select(.name == \"$ruleset_name\") | .id" <<<"$rulesets" | head -1)
  have="[]"
  if [[ -n $id ]]; then
    have=$(gh api "repos/$repo/rulesets/$id" \
      --jq '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[].context]')
  fi
  if [[ "$(jq -c sort <<<"$have")" == "$(jq -c sort <<<"$checks")" ]]; then
    echo "  ok      checks: $(jq -r 'join(", ")' <<<"$checks")"
    continue
  fi
  change "checks: $(jq -r 'if length == 0 then "none" else join(", ") end' <<<"$have") -> $(jq -r 'join(", ")' <<<"$checks")"
  ((apply)) || continue
  body=$(jq -n --arg name "$ruleset_name" --argjson checks "$checks" '{
    name: $name,
    target: "branch",
    enforcement: "active",
    conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
    bypass_actors: [{ actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always" }],
    rules: [{
      type: "required_status_checks",
      parameters: {
        strict_required_status_checks_policy: false,
        do_not_enforce_on_create: false,
        required_status_checks: ($checks | map({ context: . }))
      }
    }]
  }')
  if [[ -n $id ]]; then
    gh api -X PUT "repos/$repo/rulesets/$id" --input - --silent <<<"$body"
  else
    gh api -X POST "repos/$repo/rulesets" --input - --silent <<<"$body"
  fi
done

echo
if ((!apply)); then
  echo "$changes change(s); plan only, --apply makes them"
else
  echo "$changes change(s) made"
fi

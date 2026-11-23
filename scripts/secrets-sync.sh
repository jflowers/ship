#!/usr/bin/env bash
# Sets every repo's release secrets from the dotfiles, as repos.yaml says:
# the secret sets a repo lists, plus HOMEBREW_TAP_TOKEN for its tap. An
# owner in secrets.orgs gets one org secret per name, visible only to the
# repos that need it; any other repo gets repo secrets.
#
#   scripts/secrets-sync.sh [--apply [--prune]] [owner | owner/repo ...]
#
# Without --apply it only prints the plan. --prune also deletes the repo
# copies an org secret replaces: a repo secret wins over an org secret of
# the same name, so rotating the org secret doesn't reach a repo that still
# has its own copy. Values come from the env files under secrets.sources
# and go to gh on stdin; nothing prints them.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
config=${SHIP_REPOS:-$here/../repos.yaml}

apply=0 prune=0 targets=()
while (($#)); do
  case $1 in
    --apply) apply=1 ;;
    --prune) prune=1 ;;
    -h | --help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "secrets-sync: unknown flag $1" >&2; exit 2 ;;
    *) targets+=("$1") ;;
  esac
  shift
done
if ((prune && !apply)); then
  echo "secrets-sync: --prune needs --apply" >&2
  exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- the plan: one row per secret to set ---------------------------------
unknown=$(yq '[.repos[].secrets[]?] - (.secrets.sets | keys) | .[]' "$config")
if [[ -n $unknown ]]; then
  echo "secrets-sync: unknown secret sets: $unknown" >&2
  exit 1
fi
no_token=$(yq '[.repos[] | select(.tap) | .tap] - (.secrets.taps | keys) | unique | .[]' "$config")
if [[ -n $no_token ]]; then
  echo "secrets-sync: no secrets.taps entry for: $no_token" >&2
  exit 1
fi

# shellcheck disable=SC2016 # yq variables, not shell
# repo, name, source. (Selecting first: yq 4.53 yields an empty item when
# iterating a `// []` fallback.)
{
  yq -r '.secrets.sets as $sets | .repos | to_entries[] | select(.value.secrets) |
    .key as $repo | .value.secrets[] as $set | $sets[$set] | to_entries[] |
    [$repo, .key, .value] | @tsv' "$config"
  yq -r '.secrets.taps as $taps | .repos | to_entries[] | select(.value.tap) |
    [.key, "HOMEBREW_TAP_TOKEN", $taps[.value.tap]] | @tsv' "$config"
} | awk -F'\t' 'NF == 3 && $1 != "" && $2 != "" && $3 != ""' |
  sort -s -t $'\t' -k1,1 >"$tmp/wanted"

# kind (org|repo), target, name, source, repos: an org's repos share one
# secret per name, so they must agree on its source.
awk -F'\t' -v OFS='\t' -v orgs="$(yq '.secrets.orgs[]?' "$config" | tr '\n' ' ')" '
  BEGIN { n = split(orgs, o, " "); for (i = 1; i <= n; i++) isorg[o[i]] = 1 }
  {
    owner = $1; sub(/\/.*/, "", owner)
    if (!(owner in isorg)) { print "repo", $1, $2, $3, $1; next }
    k = owner OFS $2
    if (!(k in src)) { order[++m] = k; src[k] = $3; repos[k] = $1; next }
    if (src[k] != $3) {
      printf "secrets-sync: %s gets %s from both %s and %s; one org secret cannot be both\n",
        owner, $2, src[k], $3 > "/dev/stderr"
      bad = 1
    }
    repos[k] = repos[k] "," $1
  }
  END {
    for (i = 1; i <= m; i++) { split(order[i], p, OFS); print "org", p[1], p[2], src[order[i]], repos[order[i]] }
    exit bad
  }' "$tmp/wanted" >"$tmp/rows"

# Keep the rows a target names (an owner, or a repo the secret reaches).
if ((${#targets[@]})); then
  awk -F'\t' -v t="${targets[*]}" '
    BEGIN { n = split(t, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
    {
      owner = $2; sub(/\/.*/, "", owner)
      if (owner in want) { print; next }
      n = split($5, r, ",")
      for (i = 1; i <= n; i++) if (r[i] in want) { print; next }
    }' "$tmp/rows" >"$tmp/rows.f"
  mv "$tmp/rows.f" "$tmp/rows"
fi
if [[ ! -s $tmp/rows ]]; then
  echo "secrets-sync: nothing to sync" >&2
  exit 0
fi

# --- values ----------------------------------------------------------------
source_file() { # source name -> its env file, ~ expanded
  local f
  f=$(name="$1" yq '.secrets.sources[strenv(name)] // ""' "$config")
  [[ -n $f ]] || return 1
  printf '%s' "${f/#\~/$HOME}"
}
# KEY='value' lines (the dotfiles' secrets/README.md, "Env file format"),
# read without sourcing. macOS's bash is 3.2: no associative arrays.
value() { # name file
  local line v
  while IFS= read -r line; do
    [[ $line == "$1="* ]] || continue
    v=${line#*=} v=${v#\'} v=${v%\'}
    printf '%s' "$v"
    return
  done <"$2"
}
# resolve source name -> "file<TAB>key", or a reason on stderr
resolve() {
  local src=${1%%:*} key=$2 f
  [[ $1 == *:* ]] && key=${1#*:}
  if ! f=$(source_file "$src"); then
    echo "no secrets.sources entry \"$src\"" >&2; return 1
  fi
  if [[ ! -r $f ]]; then
    echo "$f doesn't exist (chezmoi apply)" >&2; return 1
  fi
  if [[ -z $(value "$key" "$f") ]]; then
    echo "$key is empty or missing in $f" >&2; return 1
  fi
  printf '%s\t%s' "$f" "$key"
}

# --- what's there now ------------------------------------------------------
existing() { # --repo R | --org O -> names, or "?" when gh can't list them
  local cache=$tmp/have.${2//\//_}
  if [[ ! -f $cache ]]; then
    gh secret list "$1" "$2" --json name -q '.[].name' >"$cache" 2>/dev/null || echo '?' >"$cache"
  fi
  cat "$cache"
}
has() { existing "$1" "$2" | grep -qx "$3"; }
state() { # how setting it changes things
  if existing "$1" "$2" | grep -qx '?'; then echo "can't list"
  elif has "$1" "$2" "$3"; then echo replace
  else echo new; fi
}

# --- plan / apply ----------------------------------------------------------
skipped=0 last=
while IFS=$'\t' read -r kind target name src repos; do
  if [[ $target != "$last" ]]; then
    [[ $kind == org ]] && echo "$target (org secrets)" || echo "$target"
    last=$target
  fi
  if ! where=$(resolve "$src" "$name" 2>"$tmp/why"); then
    echo "  skip    $name: $(cat "$tmp/why")"
    skipped=$((skipped + 1))
    continue
  fi
  file=${where%%$'\t'*} key=${where#*$'\t'}
  if [[ $kind == org ]]; then
    echo "  set     $name ($(state --org "$target" "$name")) for ${repos//,/, }"
    if ((apply)); then
      value "$key" "$file" |
        gh secret set "$name" --org "$target" --visibility selected --repos "${repos//$target\//}" >/dev/null
    fi
    shadow=()
    IFS=, read -r -a rs <<<"$repos"
    for r in "${rs[@]}"; do
      if has --repo "$r" "$name"; then shadow+=("$r"); fi
    done
    if ((${#shadow[@]})); then
      if ((prune)); then
        for r in "${shadow[@]}"; do
          gh secret delete "$name" --repo "$r" >/dev/null
        done
        echo "  delete  $name from ${shadow[*]}"
      else
        echo "          repo copies override it in ${shadow[*]} (--prune deletes them)"
      fi
    fi
  else
    echo "  set     $name ($(state --repo "$target" "$name"))"
    if ((apply)); then
      value "$key" "$file" | gh secret set "$name" --repo "$target" >/dev/null
    fi
  fi
done <"$tmp/rows"

if ((!apply)); then
  echo
  echo "plan only; --apply sets these"
elif ((skipped)); then
  echo "secrets-sync: skipped $skipped (see above)" >&2
  exit 1
fi

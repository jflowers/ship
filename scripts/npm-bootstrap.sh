#!/usr/bin/env bash
# First release of an npm package that isn't on npm yet. npm trusted
# publishing can only be set up on a package that already exists, so the
# first version can't come from npm-release.yml. For each npm repo in
# repos.yaml whose package isn't on npm, this:
#
#   1. publishes package.json's version (or the first version, below) from
#      a fresh clone of the default branch (npm asks for your 2FA),
#   2. waits until the registry serves it,
#   3. adds the trusted publisher (`npm trust github`), naming the repo's
#      caller workflow and, if it passes one, its environment,
#   4. dispatches the caller with the tag: ship's preflight tags it, the
#      publish is skipped because the version is on npm, and the GitHub
#      release is created.
#
#   scripts/npm-bootstrap.sh [--apply] [--first-version X.Y.Z] [owner | owner/repo ...]
#
# Without --apply it only prints the plan. A package.json version of 0.0.0
# or 0.0.0-anything (the placeholder for version_from: tag) is published as
# the first version instead, 0.1.0 unless --first-version says otherwise.
# A package already on npm whose version has no tag yet (an earlier run
# stopped part way) gets steps 3-4. A repo that isn't ready (private, caller
# not on the default branch, a build at publish time) is skipped with the
# reason.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
config=${SHIP_REPOS:-$here/../repos.yaml}
# Publishes and trusts with this npm (npm trust needs a newer one than most
# machines have); registry lookups use whatever npm is on PATH.
npm_cmd=${SHIP_NPM:-npx -y npm@11.21.2}
poll=${SHIP_POLL_SECONDS:-15}
polls=${SHIP_POLLS:-40}

apply=0 targets=() first=${SHIP_FIRST_VERSION:-0.1.0}
while (($#)); do
  case $1 in
    --apply) apply=1 ;;
    --first-version)
      (($# > 1)) || { echo "npm-bootstrap: --first-version needs a version" >&2; exit 2; }
      first=$2; shift ;;
    -h | --help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "npm-bootstrap: unknown flag $1" >&2; exit 2 ;;
    *) targets+=("$1") ;;
  esac
  shift
done
if [[ ! $first =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || $first == 0.0.0 ]]; then
  echo "npm-bootstrap: the first version must be X.Y.Z above 0.0.0, not '$first'" >&2
  exit 2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

npm() { $npm_cmd "$@"; }

wanted() { # <owner/repo>: no targets, or a target names it or its owner
  local t
  ((${#targets[@]} == 0)) && return 0
  for t in "${targets[@]}"; do
    [[ $t == "$1" || $t == "${1%%/*}" ]] && return 0
  done
  return 1
}

raw() { # <owner/repo> <path> <ref>: file contents from GitHub
  gh api -H 'Accept: application/vnd.github.raw' "repos/$1/contents/$2?ref=$3"
}

# The workflow in .github/workflows that calls ship's npm-release.yml.
caller_of() { # <owner/repo> <ref>
  local f
  for f in $(gh api "repos/$1/contents/.github/workflows?ref=$2" -q '.[].name' 2>/dev/null); do
    case $f in *.yml | *.yaml) ;; *) continue ;; esac
    if raw "$1" ".github/workflows/$f" "$2" 2>/dev/null | grep -q 'jflowers/ship/.github/workflows/npm-release.yml@'; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

# package.json's version under version_from: tag (e.g. 0.0.0-development).
placeholder() { [[ $1 == 0.0.0 || $1 == 0.0.0-* ]]; }

on_npm() { # <name> [version]; any npm can look, so skip npx's start-up
  command npm view "$1${2:+@$2}" version --prefer-online >/dev/null 2>&1
}

# --- the plan -----------------------------------------------------------
# One row per repo to act on: repo|branch|name|version|caller|env|stage|
# steps (all or trust)|package.json's version as committed.
: >"$tmp/plan"
ready=0 skipped=0
skip() { echo "skip  $repo: $1"; skipped=$((skipped + 1)); }
for repo in $(yq -r '.repos | to_entries[] | select(.value.kinds[]? == "npm") | .key' "$config"); do
  wanted "$repo" || continue

  read -r visibility branch owner_type < <(gh repo view "$repo" \
    --json visibility,defaultBranchRef,owner \
    -q '"\(.visibility) \(.defaultBranchRef.name) \(.owner.type // "User")"')
  if ! raw "$repo" package.json "$branch" >"$tmp/package.json" 2>/dev/null; then
    skip "no package.json on $branch"; continue
  fi
  # name|version|repository url|number of scripts that run at publish
  IFS='|' read -r name version url builds < <(yq -r '[.name // "", .version // "",
    (.repository | (select(tag == "!!str") // .url) // ""),
    ((.scripts // {}) | with_entries(select(.key == "prepare" or .key == "prepack" or
      .key == "prepublishOnly" or .key == "prepublish")) | length)] | map(tostring) | join("|")' "$tmp/package.json")
  if [[ -z $name || -z $version ]]; then
    skip "package.json on $branch has no name or version"; continue
  fi
  # The version as committed; a placeholder is published as $first.
  pkgver=$version
  placeholder "$version" && version=$first

  if on_npm "$name"; then
    # Bootstrapped, unless this version is on npm with no tag yet.
    if ! on_npm "$name" "$version" || gh api "repos/$repo/git/ref/tags/v$version" >/dev/null 2>&1; then
      continue
    fi
    steps=trust
  else
    steps=all
  fi

  if [[ $visibility != PUBLIC ]]; then
    skip "$name: the repo is $(echo "$visibility" | tr '[:upper:]' '[:lower:]') (npm gives no provenance from a private repo); make it public first"
    continue
  fi
  if ! caller=$(caller_of "$repo" "$branch"); then
    skip "$name: no workflow on $branch calls ship's npm-release.yml"
    continue
  fi
  norm=$(printf '%s' "$url" | sed -E 's#^(git\+)?(https?|ssh|git)://(git@)?##; s#^git@github\.com:#github.com/#; s#\.git$##')
  if [[ $norm != "github.com/$repo" ]]; then
    skip "$name: package.json repository.url is '$url', not https://github.com/$repo"
    continue
  fi
  if [[ $steps == all && $builds != 0 ]]; then
    skip "$name: it builds at publish time (a prepare/prepack/prepublishOnly script); publish the first version by hand"
    continue
  fi

  raw "$repo" ".github/workflows/$caller" "$branch" >"$tmp/caller.yml"
  # environment|stage, as the caller passes them to ship
  IFS='|' read -r env stage < <(yq -r '[
    ([.jobs[].with.environment // ""] | map(select(. != "")) | .[0] // ""),
    ([.jobs[].with.stage // ""] | map(select(. != "")) | .[0] // "auto")] | map(tostring) | join("|")' "$tmp/caller.yml")
  if [[ $stage == auto ]]; then
    stage=false
    [[ $owner_type == Organization ]] && stage=true
  fi

  verb=publish
  [[ $stage == true ]] && verb=stage
  from=
  [[ $pkgver != "$version" ]] && from=" (package.json has the placeholder $pkgver)"
  case $steps in
    all) what="$verb $name@$version$from, trust $caller${env:+ (environment $env)}, dispatch v$version" ;;
    trust) what="$name@$version is on npm with no tag: trust $caller${env:+ (environment $env)}, dispatch v$version" ;;
  esac
  echo "ready $repo: $what"
  # `|`, not a tab: read collapses runs of whitespace, so an empty env
  # would shift every field after it.
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$repo" "$branch" "$name" "$version" "$caller" "$env" "$stage" "$steps" "$pkgver" >>"$tmp/plan"
  ready=$((ready + 1))
done

echo "$ready ready, $skipped skipped"
if ((!apply)); then
  ((ready)) && echo "Run with --apply to do it; npm asks for your 2FA on the first publish and the first trust."
  exit 0
fi
((ready)) || exit 0

# --- apply --------------------------------------------------------------
# Without a valid login npm answers a new package's publish with 404, not
# 401, which reads like a missing package. Check first, before any clone.
if ! user=$(npm whoami 2>/dev/null); then
  echo "npm-bootstrap: npm isn't logged in (npm whoami failed); run npm login, then this again" >&2
  exit 1
fi
echo "Publishing as npm user $user"
failed=0
# The plan comes in on fd 3 so stdin stays your terminal: npm only waits
# for the 2FA web login when stdin is a TTY, and fails with EOTP otherwise.
while IFS='|' read -r repo branch name version caller env stage steps pkgver <&3; do
  echo
  echo "== $repo ($name@$version)"
  if [[ $steps == all ]]; then
    dir=$tmp/clone-${repo//\//-}
    gh repo clone "$repo" "$dir" -- --quiet --depth 1 --branch "$branch"
    # The checked-out version must be the one the plan read.
    got=$(yq -r '.version' "$dir/package.json")
    if [[ $got != "$pkgver" ]]; then
      echo "npm-bootstrap: $repo's $branch moved to $got since the plan; run it again" >&2
      failed=$((failed + 1)); continue
    fi
    # A placeholder: publish the planned first version, as the release
    # workflow sets it from the tag.
    if [[ $pkgver != "$version" ]] &&
      ! (cd "$dir" && npm version "$version" --no-git-tag-version --allow-same-version >/dev/null); then
      echo "npm-bootstrap: setting $name's version to $version failed" >&2
      failed=$((failed + 1)); continue
    fi
    publish=(publish --access public --ignore-scripts)
    [[ $stage == true ]] && publish=(stage publish --access public --ignore-scripts)
    if ! (cd "$dir" && npm "${publish[@]}"); then
      echo "npm-bootstrap: publishing $name failed" >&2
      failed=$((failed + 1)); continue
    fi
    if [[ $stage == true ]]; then
      echo "Staged: approve $name@$version on npmjs.com (Staged Packages), then run this again to add the trusted publisher and dispatch."
      continue
    fi
    echo "Waiting for the registry to serve $name@$version..."
    n=0
    until on_npm "$name" "$version"; do
      n=$((n + 1))
      if ((n >= polls)); then
        echo "npm-bootstrap: $name@$version still isn't on the registry; run this again later to finish" >&2
        failed=$((failed + 1)); continue 2
      fi
      sleep "$poll"
    done
  fi

  if npm trust list "$name" --json 2>/dev/null | grep -q "$caller"; then
    echo "The trusted publisher for $name already names $caller."
  else
    trust=(trust github "$name" --repo "$repo" --file "$caller" -y)
    [[ -n $env ]] && trust+=(--env "$env")
    if [[ $stage == true ]]; then trust+=(--allow-stage-publish); else trust+=(--allow-publish); fi
    if ! npm "${trust[@]}"; then
      echo "npm-bootstrap: adding the trusted publisher for $name failed" >&2
      failed=$((failed + 1)); continue
    fi
    sleep 2 # npm asks for a pause between trust calls
  fi

  if ! gh workflow run "$caller" -R "$repo" --ref "$branch" -f "tag=v$version"; then
    echo "npm-bootstrap: dispatching $caller in $repo failed" >&2
    failed=$((failed + 1)); continue
  fi
  echo "Dispatched v$version: gh run list -R $repo -w $caller -L 1"
done 3<"$tmp/plan"

((failed == 0)) || { echo "$failed failed"; exit 1; }

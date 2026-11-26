# ship

Shared release workflows for my repos in `jflowers`, `unbound-force` and
`zero-dot-force`, so every project releases the same way and a fix lands
once. Modeled on [complytime/org-infra](https://github.com/complytime/org-infra),
whose preflight and GoReleaser workflows this builds on.

[`repos.yaml`](repos.yaml) lists every repo that publishes something, what it
publishes, its Homebrew tap, its mise pin, and whether it has migrated.

ship lives in a personal account on purpose. Callers pin it by full commit
SHA, so the code they run can't change under them. They do depend on this
account staying available: if it were renamed, deleted or compromised,
releases would stop until the callers were repointed.

## Workflows

### `go-release.yml`: Go CLI, optionally signed for macOS and published as a cask

1. **Settings**: before anything is tagged, checks the secrets. Signing needs
   `MACOS_SIGN_P12`, `MACOS_SIGN_PASSWORD` and the three `MACOS_NOTARY_*`;
   none of them means an unsigned release, and some but not all fails the
   run, naming the missing ones. A `tap` without `HOMEBREW_TAP_TOKEN` fails
   too.
2. **Preflight** (org-infra): semver, tag uniqueness, CI on HEAD, unreleased
   commits; creates the tag.
3. **GoReleaser** (org-infra): archives, checksums, cosign, SBOMs.
4. **Sign + notarize macOS**: every `<prefix>_*_darwin_*.tar.gz` is signed with
   the Developer ID, notarized, re-uploaded, and its line in `checksums.txt`
   rewritten. Skipped when no signing secrets are passed.
5. **Publish cask**: every `sha256` in the cask is set from the final
   `checksums.txt`, the cask is committed in a clone of the tap and checked
   with `brew audit --cask --strict` (on macOS, through a throwaway tap), then
   pushed. A push rejected because another repo pushed to the same tap first
   is rebased and retried (5 tries); a conflict on the same cask fails
   instead of overwriting.

   With `formula`, the GoReleaser formula (release asset `<formula>-formula.rb`)
   gets the same sha256 rewrite and is committed as `Formula/<formula>.rb`;
   brew must load it (GoReleaser formulas can't pass `brew audit`: a
   redundant `version`, no `test do`). With `cask_install_check`, the
   candidate cask is installed from the tap clone on macOS and the check runs
   (`$HOMEBREW_PREFIX` set) before anything is pushed.

After the release, two optional checks install it the way users do:

- **`go_install`** (a package, e.g. `github.com/org/tool/v2/cmd/tool`):
  `go install <pkg>@<tag>` from the module proxy with an empty cache
  (retried, since the proxy can lag a new tag), then the binary's build
  info must name that package at the tag; `go_install_check` runs with
  `$BIN` set. This is what `go install` and mise's `go:` backend users get,
  unsigned and built from source.
- **`tap_install_check`**: once the cask is pushed, `brew install --cask`
  from the published tap on macOS, then the check (`$HOMEBREW_PREFIX` set).

This replaces the sign-and-notarize jobs copied into replicator, dewey, gaze
and unbound-force, and pins org-infra in one place.

A repo's whole `release.yml`:

```yaml
name: Release
on:
  workflow_dispatch:
    inputs:
      tag: { description: "Release tag (e.g. v0.2.0)", required: true, type: string }
permissions: {}
jobs:
  release:
    uses: jflowers/ship/.github/workflows/go-release.yml@<sha> # vX.Y.Z
    with:
      tag: ${{ inputs.tag }}
      ci_checks: '["Build and Test"]'
      tap: unbound-force/homebrew-tap
    permissions:
      contents: write
      checks: read
      id-token: write
    # Map secrets by name: `secrets: inherit` only crosses into a workflow in
    # the same org/enterprise, and ship lives in jflowers.
    secrets:
      MACOS_SIGN_P12: ${{ secrets.MACOS_SIGN_P12 }}
      MACOS_SIGN_PASSWORD: ${{ secrets.MACOS_SIGN_PASSWORD }}
      MACOS_NOTARY_KEY: ${{ secrets.MACOS_NOTARY_KEY }}
      MACOS_NOTARY_KEY_ID: ${{ secrets.MACOS_NOTARY_KEY_ID }}
      MACOS_NOTARY_ISSUER_ID: ${{ secrets.MACOS_NOTARY_ISSUER_ID }}
      HOMEBREW_TAP_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
```

Inputs: `tag`, `ci_checks`, `allow_prerelease` (default true),
`skip_semver_check`, `skip_ci_checks`, `skip_unreleased_check`, `binary`,
`archive_prefix`, `cask` (these three default to the repo name), and `tap`.

Secrets (all optional): `MACOS_SIGN_P12`, `MACOS_SIGN_PASSWORD`,
`MACOS_SIGN_IDENTITY` (found in the .p12 when absent), `MACOS_NOTARY_KEY`,
`MACOS_NOTARY_KEY_ID`, `MACOS_NOTARY_ISSUER_ID`, `HOMEBREW_TAP_TOKEN`
(required when `tap` is set). A repo whose secret has another name maps that
name onto these.

The caller's `.goreleaser.yaml` keeps its cask as a release asset and lets
the workflow push it:

```yaml
homebrew_casks:
  - name: replicator
    directory: Casks
    skip_upload: true
    # Homebrew 7's postflight_steps needs a literal {{staged_path}}:
    # "#{staged_path}" makes the cask unreadable and fails the audit, and a
    # bare {{staged_path}} fails GoReleaser's own templating, hence the escape.
    custom_block: |
      postflight_steps do
        on_macos do
          run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{ `{{staged_path}}` }}/replicator"]
        end
      end
release:
  extra_files:
    - glob: dist/homebrew/Casks/replicator.rb
```

### `npm-release.yml`: npm package, through trusted publishing

A release is one dispatch, plus your 2FA approval on npmjs.com when the
version is staged:

```bash
gh workflow run publish.yml -f tag=v1.2.3
```

There's no version bump to commit first. The version comes from the tag
(`version_from: tag`, the default): publish sets it in the checked-out
`package.json` just before publishing, without a commit. The tag, the
GitHub release and npm record which version is released. Keep a
placeholder in `package.json` so the repo doesn't show a stale number:

```json
"version": "0.0.0-development",
```

A real version there still works (the tag overrides it), but it goes stale
after the next release. With `version_from: package`, `package.json` must
hold the released version instead, so every release needs a bump committed
first.

1. **Settings**: before anything is tagged, checks the run is on the default
   branch and `version_from` is `tag` or `package`, decides whether to stage
   (below), and checks `npm_version` is new enough (11.5.1 to publish,
   11.15.0 to stage). Then it checks `package.json` on the commit about to
   be tagged:
   - `repository.url` must be this repo, or trusted publishing fails;
   - with `version_from: package`, the version must equal the tag. A
     forgotten bump fails here, with nothing tagged: bump it and dispatch
     the same tag again.
2. **Preflight** (org-infra): semver, tag uniqueness, CI on HEAD, unreleased
   commits; creates the tag.
3. **Publish**: checks out the tag and checks `package.json` again. If the
   version is already on npm (an earlier run, approved), the rest of the
   job is skipped and the run goes on to the GitHub release, so a re-run is
   safe.

   Then it runs `install` and `checks`, sets the version from the tag, and
   publishes with provenance, or
   stages the version for a maintainer to approve on npmjs.com. A prerelease
   (`v1.2.0-rc.1`) goes to the `next` dist-tag, not `latest`.
4. **GitHub release**: creates the release for the tag with generated notes
   (a prerelease for `-suffix` tags), unless it exists. A staged version
   shows here before it's public; if you reject it on npm, delete the
   release by hand. The tag stays.

**Staging.** With `stage: auto` (the default), a package whose repo belongs
to an organization is staged, so nothing reaches npm without a
maintainer's 2FA approval, and a package in a personal account is
published straight away. `stage: true` or `false` overrides that.

There's no npm token. npm trusts the *calling* workflow: the trusted
publisher on npmjs.com names the caller's file (say `publish.yml`), never
`npm-release.yml`, so a repo keeps its registered file as the caller, and
renaming it breaks publishing until the trusted publisher is updated. If the
trusted publisher names a GitHub environment, pass it as `environment`.

Lifecycle scripts don't run at publish (`--ignore-scripts`), so `checks`
must build whatever the package ships.

A repo's whole `publish.yml`:

```yaml
name: Publish
on:
  workflow_dispatch:
    inputs:
      tag: { description: "Release tag (e.g. v0.5.0)", required: true, type: string }
permissions: {}
jobs:
  release:
    uses: jflowers/ship/.github/workflows/npm-release.yml@<sha> # vX.Y.Z
    with:
      tag: ${{ inputs.tag }}
      ci_checks: '["typecheck and test"]'
      bun_version: 1.4.4
      install: bun install --frozen-lockfile
      checks: |
        bun run typecheck
        bun test
        bun run verify:package
    permissions:
      contents: write
      checks: read
      id-token: write
```

Inputs: `tag`, `ci_checks`, `allow_prerelease` (default true),
`skip_semver_check`, `skip_ci_checks`, `skip_unreleased_check`,
`version_from` (`tag` or `package`, default `tag`), `stage` (`auto`,
`true` or `false`, default `auto`), `github_release` (default true),
`environment`, `node_version` (default 24), `bun_version` (empty: no Bun),
`npm_version` (default 11.21.2), `install` (default `npm ci`) and `checks`.

**A package's first release.** npm only accepts a trusted publisher for a
package that already exists, so the first version can't come from this
workflow. [`scripts/npm-bootstrap.sh`](scripts/npm-bootstrap.sh) does it
for every npm repo in `repos.yaml` whose package isn't on npm yet:

1. publishes the first version from a fresh clone of the default branch
   (staged instead, in an organization), which asks for your 2FA. That's
   `package.json`'s version, or, when it's a placeholder (`0.0.0` or
   `0.0.0-anything`), `0.1.0` or the version given with `--first-version`;
2. waits until the registry serves it;
3. adds the trusted publisher with `npm trust github`, naming the repo's
   caller workflow and its `environment`, allowing publishing or staging
   to match `stage`;
4. dispatches the caller with the tag. Preflight tags it, the publish is
   skipped because the version is on npm, and the GitHub release is
   created.

```bash
scripts/npm-bootstrap.sh                                         # plan: what's ready, and why the rest isn't
scripts/npm-bootstrap.sh --apply                                 # all of them
scripts/npm-bootstrap.sh --apply jflowers/opencode-session-notes # just one repo (or owner)
scripts/npm-bootstrap.sh --apply --first-version 1.0.0 acme/new  # a placeholder's first version, if not 0.1.0
```

Before it changes anything, `--apply` checks `npm whoami` and stops if npm
isn't logged in: without a login, npm answers a new package's publish with
a misleading 404. Run `npm login` and try again.

npm asks for 2FA on each publish and on the first `npm trust`, where the
web prompt's "skip two-factor authentication for the next 5 minutes" covers
the later `npm trust` calls. A repo is skipped, with the reason, if it's private (npm gives no
provenance from a private repo), if no workflow on its default branch calls
`npm-release.yml`, if `repository.url` isn't the repo, or if it builds at
publish time (publish that one's first version by hand). A staged package
stops after staging: approve it on npmjs.com and run the script again,
which finishes it with steps 3 and 4. So does any package whose version is
on npm but has no tag yet.

### `tag-release.yml`: the tag and GitHub release, for assets built elsewhere

The front half of every ship release, for a repo whose assets no other ship
workflow builds:

1. **Settings**: the run is on the default branch.
2. **Preflight** (org-infra): semver, tag uniqueness, CI on HEAD, unreleased
   commits; creates the tag.
3. **GitHub release**: created for the tag with generated notes (a
   prerelease for a `vX.Y.Z-suffix` tag), unless it exists.

It outputs `tag`. The caller's own jobs, or `mac-app-release.yml`, `needs:`
it, check out that tag and upload their assets to the release. Caller
permissions: `contents: write`, `checks: read`.

### `mac-app-release.yml`: a signed, notarized Mac app and its cask

Adds a Mac app to a release `tag-release.yml` made:

1. **Settings**: the tag is `vX.Y.Z`; all five signing secrets are passed (a
   Mac app is always signed and notarized); a `tap` has `HOMEBREW_TAP_TOKEN`
   and a `cask_desc`.
2. **Build, sign + notarize** (macOS): checks out the tag, runs `checks`,
   then `build` with `$VERSION` (no v) set, which leaves the .app at `app`
   (ad hoc signed is fine). The .app is signed with the Developer ID
   (hardened runtime, timestamp), notarized, stapled, checked with
   `spctl`, and uploaded as `<zip_prefix>_<version>.zip` (`<repo>-app` by
   default), replacing any earlier upload.
3. **Publish cask**: writes `Casks/<cask>.rb` for that zip (`desc`,
   `homepage`, and `depends_on macos: ">= :<macos>"` when `macos` is set),
   then commits, audits and pushes it as `go-release.yml` does. Skipped
   without a `tap`, and for a prerelease tag.

gh-hud's `release.yml`, with its Android job beside the Mac app:

```yaml
name: Release
on:
  workflow_dispatch:
    inputs:
      tag: { description: "Release tag (e.g. v0.4.0)", required: true, type: string }
permissions: {}
concurrency:
  group: release
  cancel-in-progress: false
jobs:
  release:
    uses: jflowers/ship/.github/workflows/tag-release.yml@<sha> # vX.Y.Z
    with:
      tag: ${{ inputs.tag }}
      ci_checks: '["Lint", "Test (ubuntu-latest)", "Vulnerabilities"]'
    permissions:
      contents: write
      checks: read
  mac-app:
    needs: release
    if: needs.release.outputs.tag != ''
    uses: jflowers/ship/.github/workflows/mac-app-release.yml@<sha> # vX.Y.Z
    with:
      tag: ${{ needs.release.outputs.tag }}
      checks: make mac-check
      build: make mac MAC_VERSION="$VERSION" MAC_ARCHS="arm64 x86_64"
      app: build/gh-hud.app
      tap: jflowers/homebrew-tools
      cask_desc: Dashboard for GitHub work and coding agents, a client of the gh-hud hub
      macos: sonoma
    secrets:
      MACOS_SIGN_P12: ${{ secrets.MACOS_SIGN_P12 }}
      MACOS_SIGN_PASSWORD: ${{ secrets.MACOS_SIGN_PASSWORD }}
      MACOS_NOTARY_KEY: ${{ secrets.MACOS_NOTARY_KEY }}
      MACOS_NOTARY_KEY_ID: ${{ secrets.MACOS_NOTARY_KEY_ID }}
      MACOS_NOTARY_ISSUER_ID: ${{ secrets.MACOS_NOTARY_ISSUER_ID }}
      HOMEBREW_TAP_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
    permissions:
      contents: write
  android-app:
    needs: release
    if: needs.release.outputs.tag != ''
    # ... checks out refs/tags/${{ needs.release.outputs.tag }}, builds the APK, uploads it
```

### `deps-automerge.yml` and `renovate/automerge.json`: our own updates merge themselves

complytime/org-infra's `ci_dependencies.yml` policy, merged by rebase.
Patch and minor updates of packages from our own orgs (jflowers,
unbound-force, zero-dot-force: their actions and reusable workflows, Go
modules, `@scope` npm packages) merge themselves once the required checks
pass. That includes the bumps to a repo's own `jflowers/ship/...@<sha>`
pins, so each repo picks up a ship release by itself. Third-party
updates wait a day and a person merges them. Majors, and updates without a
semver type, always wait for a person.

**Dependabot.** Add a caller and a cooldown. The cooldown replaces
org-infra's 24h release-age check: Dependabot doesn't open a PR for a
third-party release younger than that. Our orgs are excluded, as org-infra
skips the check for them.

```yaml
# .github/workflows/dependabot-automerge.yml
name: Dependabot auto-merge
on: pull_request
permissions: {}
jobs:
  automerge:
    uses: jflowers/ship/.github/workflows/deps-automerge.yml@<sha> # vX.Y.Z
    permissions:
      contents: write
      pull-requests: write
```

```yaml
# .github/dependabot.yml, on each update (Go modules: github.com/jflowers/* ...)
    cooldown:
      default-days: 1
      exclude: ["jflowers/*", "unbound-force/*", "zero-dot-force/*"]
```

The job runs only for Dependabot's own PRs from a branch in the repo. It
reads the update type and the dependencies with
`dependabot/fetch-metadata`, then, for a safe update, blocks on
`actions/dependency-review-action`. For a safe update from our orgs it
checks that the repo allows auto-merge and that the base branch requires at
least one status check, then runs `gh pr merge --auto --rebase`. Without a
required check auto-merge would merge before CI, so the job fails instead.
A group with any third-party dependency in it is third-party.

Inputs: `owners` (our three orgs), `merge_method` (`rebase`),
`max_update_type` (`minor`), `dependency_review` (true; it needs the
dependency graph, which `settings-sync.sh` turns on), `approve` (false;
approves every safe update, as org-infra does, for a branch that requires a
review and with "Allow GitHub Actions to create and approve pull requests"
on). A merge made with `GITHUB_TOKEN` starts no `push` workflows on the
default branch.

**Renovate.** Extend the preset:

```json
{ "extends": ["config:recommended", "github>jflowers/ship//renovate/automerge#vX.Y.Z"] }
```

Same policy: third-party updates wait a day (`minimumReleaseAge`) and stay
open for a person; non-major updates from our orgs have no wait and
Renovate turns on GitHub auto-merge for them, by rebase.

## Settings

`repos.yaml`'s `settings:` is the GitHub settings every repo there should
have; a repo's own `settings:` overrides them and its `checks:` are the
status checks its default branch requires.

```bash
scripts/settings-sync.sh [--apply] [owner | owner/repo ...]
```

Without `--apply` it prints the plan. Defaults: Dependabot alerts (which
turn on the dependency graph that `dependency-review-action` needs),
Dependabot security updates, auto-merge, rebase merges, and deleting merged
branches. `checks:` go in one ruleset, `ship: required checks`, which
repository admins bypass, so you can still push to the default branch. A
repo without `checks:` keeps the rulesets and branch protection it has; the
plan shows them.

Owners in `settings.skip` are left alone: unbound-force and zero-dot-force
manage their repos' settings with safe-settings, in `safe-settings/` of
their `.github` repos, so a setting deps-automerge.yml needs there (auto-merge,
a required check) goes in a PR to that repo instead. Their code repos also
require a code owner's approval, so our own updates there merge themselves
once you approve them.

### `container-image.yml`: a multi-arch container image

1. **Settings**: `image` is `registry/path` with no tag, every tag is valid,
   and a `push` has `REGISTRY_USERNAME` and `REGISTRY_PASSWORD`.
2. **Build** (amd64 on `ubuntu-latest`, arm64 on `ubuntu-24.04-arm`, no
   QEMU): `podman build`, then the caller's `smoke` commands with `$IMAGE`
   set to the local image.
3. **Push manifest** (only with `push: true`): logs in to the image's
   registry with the password on stdin, and pushes one manifest for both
   architectures under every tag in `tags`.

It isn't a release: there's no tag or preflight. Pass
`push: ${{ github.event_name != 'pull_request' }}` so pull requests build
and smoke-test without pushing. unbound-force/containerfile's dev image:

```yaml
jobs:
  image:
    uses: jflowers/ship/.github/workflows/container-image.yml@<sha> # vX.Y.Z
    with:
      image: quay.io/unbound-force/opencode-dev
      tags: ${{ github.ref_type == 'tag' && format('{0} latest', github.ref_name) || 'latest' }}
      push: ${{ github.event_name == 'push' }}
      smoke: |
        podman run --rm "$IMAGE" uf --version
        test "$(podman run --rm --entrypoint whoami "$IMAGE")" = dev
    permissions:
      contents: read
    secrets:
      REGISTRY_USERNAME: ${{ secrets.QUAY_USERNAME }}
      REGISTRY_PASSWORD: ${{ secrets.QUAY_PASSWORD }}
```

### `cue-release.yml`: a CUE module on the CUE Central Registry

1. **Settings**: the run is on the default branch, and the tag's major
   version is the one `cue.mod/module.cue` names (`@v0` takes `v0.x.y`).
2. **Preflight** (org-infra): semver, tag uniqueness, CI on HEAD,
   unreleased commits; creates the tag.
3. **Publish**: checks out the tag, logs in to the registry with the run's
   OIDC token (`cue-labs/registry-login-action`), and runs
   `cue mod publish <tag>`.
4. **GitHub release**: created once the module is published, with generated
   notes (a prerelease for a `vX.Y.Z-suffix` tag).

The registry must trust the caller's repository
([registry.cue.works/account/oidc](https://registry.cue.works/account/oidc));
the token names the caller's repository, not ship. Caller permissions:
`contents: write`, `checks: read`, `id-token: write`.

```yaml
jobs:
  release:
    uses: jflowers/ship/.github/workflows/cue-release.yml@<sha> # vX.Y.Z
    with:
      tag: ${{ inputs.tag }}
      cue_version: v0.17.0
      ci_checks: '["test"]'
    permissions:
      contents: write
      checks: read
      id-token: write
```

## Secrets

ship holds no secrets. Each caller passes its own, and
[`scripts/secrets-sync.sh`](scripts/secrets-sync.sh) sets them all from the
dotfiles, as [`repos.yaml`](repos.yaml) says:

- `secrets.sources`: the env files chezmoi decrypts from `secrets/*.age`
  (`~/.config/apple-developer`, `~/.config/android-release`).
- `secrets.sets`: named groups (`macos-sign`, `android-sign`); a repo lists
  the ones its release needs under `secrets:`.
- `secrets.taps`: which key holds each tap's token; a repo with a `tap` gets
  it as `HOMEBREW_TAP_TOKEN`.
- `secrets.orgs`: owners that get one org secret per name, visible only to
  the repos that need it, instead of a copy in each repo. jflowers is a
  personal account, so its repos get repo secrets.

```bash
scripts/secrets-sync.sh                          # plan: what it would set, and what's missing
scripts/secrets-sync.sh --apply                  # set them all
scripts/secrets-sync.sh --apply jflowers/gh-hud  # just one repo (or owner)
scripts/secrets-sync.sh --apply --prune unbound-force
```

A repo secret overrides an org secret of the same name, so once the org
secrets are set, `--prune` deletes the repo copies they replace; until then
a rotation doesn't reach those repos. Org secrets need the `admin:org`
scope (`gh auth refresh -s admin:org`). Rotating the Developer ID or notary
key is: update the `.age` file, `chezmoi apply`, `secrets-sync.sh --apply`.

`MACOS_SIGN_IDENTITY` isn't synced: `go-release.yml` and
`mac-app-release.yml` read it from the .p12.

Since callers hand these secrets to code in this repo, pin `uses:` to a
SHA, never `@main`, and keep `main` protected.

## Sync check

`scripts/sync-check.sh` checks every repo in `repos.yaml` against its own
workflows, read with `gh`: that it calls the ship workflows its entry lists,
pinned to a ship tag; that a `go-release.yml` caller passes its `tap`, its
`HOMEBREW_TAP_TOKEN` and the `go_install` package mise installs; and that its
secret sets are used. It fails on any of those. An older pin, a pin
`repos.yaml` doesn't record (Dependabot's ship group moves pins on its own),
and a missing `go_install` or `tap_install_check` are warnings.
`sync-check.yml` runs it every Monday and on dispatch, with the report in the
run's summary.

## Develop

```bash
mise install
actionlint && shellcheck scripts/*.sh && scripts/test-steps.sh && scripts/test-npm-steps.sh && scripts/test-mac-app-steps.sh && scripts/test-container-steps.sh && scripts/test-post-release.sh && scripts/test-npm-bootstrap.sh && scripts/test-secrets-sync.sh && scripts/test-deps-automerge.sh && scripts/test-sync-check.sh
scripts/test-audit-cask.sh   # macOS
```

`scripts/test-steps.sh` runs the workflow's own shell steps (read out with
yq, so the workflow is the only copy): the checksum rewrite and cask patch
against a real GoReleaser 2.15 cask in `scripts/testdata/`, and the tap push
retry against a local bare repo. `scripts/test-audit-cask.sh` (macOS) runs
the audit step on that cask. `scripts/test-npm-steps.sh` runs
`npm-release.yml`'s settings, both `package.json` checks and the GitHub
release step against fixture packages, a fake `npm view` and a fake `gh`.
`scripts/test-mac-app-steps.sh` runs `mac-app-release.yml`'s settings and cask
writer and `tag-release.yml`'s branch check, and checks that the signing
import and tap steps it shares with `go-release.yml` haven't drifted;
`test-audit-cask.sh` also audits a cask it writes.
`scripts/test-container-steps.sh` runs `container-image.yml`'s settings check.
`scripts/test-post-release.sh` runs `go-release.yml`'s post-release `go install`
check against a fake `go`; `test-audit-cask.sh` also installs a cask from a
tap by its `owner/homebrew-name` (on CI only).
`scripts/test-npm-bootstrap.sh` runs the bootstrap's plan and `--apply`
against fixture repos, a fake `gh` and a fake `npm`.
`scripts/test-secrets-sync.sh` runs the sync
against a fixture config, a fake `HOME` and a fake `gh`.
`scripts/test-deps-automerge.sh` runs `deps-automerge.yml`'s decide and gate
steps and `settings-sync.sh` against a fake `gh`.
`scripts/test-sync-check.sh` runs `sync-check.sh` against a fixture
`repos.yaml` and fixture workflows.

## Roadmap

- A GitHub App token for tap pushes instead of `HOMEBREW_TAP_TOKEN`
- `gh ship status | release | secrets`, driven by `repos.yaml`
  (`secrets-sync.sh` becomes `gh ship secrets`)
- gh-hud: a Releases view, and `toolkit.toml` generated from `repos.yaml`

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
version is staged.

1. **Settings**: before anything is tagged, checks the run is on the default
   branch and `version_from` is `package` or `tag`, decides whether to stage
   (below), and checks `npm_version` is new enough (11.5.1 to publish,
   11.15.0 to stage). Then it checks `package.json` on the commit about to
   be tagged:
   - `repository.url` must be this repo, or trusted publishing fails;
   - the version must equal the tag (`version_from: package`), unless it's
     set from the tag (`version_from: tag`).

   A forgotten bump fails here, with nothing tagged: bump it and dispatch
   the same tag again.
2. **Preflight** (org-infra): semver, tag uniqueness, CI on HEAD, unreleased
   commits; creates the tag.
3. **Publish**: checks out the tag and checks `package.json` again. If the
   version is already on npm (an earlier run, approved), the rest of the
   job is skipped and the run goes on to the GitHub release, so a re-run is
   safe.

   Then it runs `install` and `checks`, and publishes with provenance, or
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
`version_from` (`package` or `tag`, default `package`), `stage` (`auto`,
`true` or `false`, default `auto`), `github_release` (default true),
`environment`, `node_version` (default 24), `bun_version` (empty: no Bun),
`npm_version` (default 11.21.2), `install` (default `npm ci`) and `checks`.

**A package's first release.** npm only accepts a trusted publisher for a
package that already exists, so the first version can't come from this
workflow. [`scripts/npm-bootstrap.sh`](scripts/npm-bootstrap.sh) does it
for every npm repo in `repos.yaml` whose package isn't on npm yet:

1. publishes `package.json`'s version from a fresh clone of the default
   branch (staged instead, in an organization), which asks for your 2FA;
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

`MACOS_SIGN_IDENTITY` isn't synced: `go-release.yml` reads it from the .p12.

Since callers hand these secrets to code in this repo, pin `uses:` to a
SHA, never `@main`, and keep `main` protected.

## Develop

```bash
mise install
actionlint && shellcheck scripts/*.sh && scripts/test-steps.sh && scripts/test-npm-steps.sh && scripts/test-npm-bootstrap.sh && scripts/test-secrets-sync.sh
scripts/test-audit-cask.sh   # macOS
```

`scripts/test-steps.sh` runs the workflow's own shell steps (read out with
yq, so the workflow is the only copy): the checksum rewrite and cask patch
against a real GoReleaser 2.15 cask in `scripts/testdata/`, and the tap push
retry against a local bare repo. `scripts/test-audit-cask.sh` (macOS) runs
the audit step on that cask. `scripts/test-npm-steps.sh` runs
`npm-release.yml`'s settings, both `package.json` checks and the GitHub
release step against fixture packages, a fake `npm view` and a fake `gh`.
`scripts/test-npm-bootstrap.sh` runs the bootstrap's plan and `--apply`
against fixture repos, a fake `gh` and a fake `npm`.
`scripts/test-secrets-sync.sh` runs the sync
against a fixture config, a fake `HOME` and a fake `gh`.

## Roadmap

- `formula` support (unbound-force/unbound-force), the post-release install
  check from gaze, `container`, `pypi` publishing, `mac-app`
  (from gh-hud)
- A GitHub App token for tap pushes instead of `HOMEBREW_TAP_TOKEN`
- `gh ship status | release | secrets`, driven by `repos.yaml`
  (`secrets-sync.sh` becomes `gh ship secrets`)
- A sync job that keeps each repo's `release.yml` current; Renovate for the
  `@<sha>` pins
- gh-hud: a Releases view, and `toolkit.toml` generated from `repos.yaml`

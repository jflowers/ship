# ship

Shared release workflows for my repos in `jflowers`, `unbound-force` and
`zero-dot-force`, so every project releases the same way and a fix lands
once. Modeled on [complytime/org-infra](https://github.com/complytime/org-infra),
whose preflight and GoReleaser workflows this builds on.

[`repos.yaml`](repos.yaml) lists every repo that publishes something, what it
publishes, its Homebrew tap, its mise pin, and whether it has migrated.

## Workflows

### `go-release.yml`: Go CLI, optionally signed for macOS and published as a cask

1. **Preflight** (org-infra): semver, tag uniqueness, CI on HEAD, unreleased
   commits; creates the tag.
2. **GoReleaser** (org-infra): archives, checksums, cosign, SBOMs.
3. **Sign + notarize macOS**: every `<prefix>_*_darwin_*.tar.gz` is signed with
   the Developer ID, notarized, re-uploaded, and its line in `checksums.txt`
   rewritten. Skipped when `MACOS_SIGN_P12` isn't passed.
4. **Publish cask**: every `sha256` in the cask is set from the final
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
actionlint && shellcheck scripts/*.sh && scripts/test-steps.sh && scripts/test-secrets-sync.sh
scripts/test-audit-cask.sh   # macOS
```

`scripts/test-steps.sh` runs the workflow's own shell steps (read out with
yq, so the workflow is the only copy): the checksum rewrite and cask patch
against a real GoReleaser 2.15 cask in `scripts/testdata/`, and the tap push
retry against a local bare repo. `scripts/test-audit-cask.sh` (macOS) runs
the audit step on that cask. `scripts/test-secrets-sync.sh` runs the sync
against a fixture config, a fake `HOME` and a fake `gh`.

## Roadmap

- `formula` support (unbound-force/unbound-force), the post-release install
  check from gaze, `container`, `npm`/`pypi` publish actions, `mac-app`
  (from gh-hud)
- A GitHub App token for tap pushes instead of `HOMEBREW_TAP_TOKEN`
- `gh ship status | release | secrets`, driven by `repos.yaml`
  (`secrets-sync.sh` becomes `gh ship secrets`)
- A sync job that keeps each repo's `release.yml` current; Renovate for the
  `@<sha>` pins
- gh-hud: a Releases view, and `toolkit.toml` generated from `repos.yaml`

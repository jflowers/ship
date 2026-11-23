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

## Develop

```bash
mise install
actionlint && shellcheck scripts/*.sh && scripts/test-steps.sh
scripts/test-audit-cask.sh   # macOS
```

`scripts/test-steps.sh` runs the workflow's own shell steps (read out with
yq, so the workflow is the only copy): the checksum rewrite and cask patch
against a real GoReleaser 2.15 cask in `scripts/testdata/`, and the tap push
retry against a local bare repo. `scripts/test-audit-cask.sh` (macOS) runs
the audit step on that cask.

## Roadmap

- `formula` support (unbound-force/unbound-force), the post-release install
  check from gaze, `container`, `npm`/`pypi` publish actions, `mac-app`
  (from gh-hud)
- A GitHub App token for tap pushes instead of `HOMEBREW_TAP_TOKEN`
- `gh ship status | release | secrets sync`, driven by `repos.yaml`
- A sync job that keeps each repo's `release.yml` current; Renovate for the
  `@<sha>` pins
- gh-hud: a Releases view, and `toolkit.toml` generated from `repos.yaml`

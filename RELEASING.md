# Releasing

The package is published to [Hex](https://hex.pm/packages/docuconf_gleam)
as `docuconf_gleam` with `gleam publish`, by
`.github/workflows/release.yml` when a `v*` tag is pushed. Docs go to
HexDocs at the same time.

The Hex name is `docuconf_gleam` because Hex has one namespace for Erlang,
Elixir and Gleam packages, and the Elixir SDK (docuconf-elixir) is named
`docuconf`. The module names stay `docuconf`, `docuconf/duration` and so
on, so code reads `import docuconf` either way.

## Before the first release

1. **Check the name is free**: <https://hex.pm/packages/docuconf_gleam>
   should not exist yet. After the release, change the README's Install
   section from the git dependency to `gleam add docuconf_gleam`.
2. **Create an API key.** Hex has no OIDC trusted publishing. Create a key
   that can publish (`mix hex.user key generate --permission api:write`, or
   on hex.pm under Dashboard, Keys) and store it as the `HEXPM_API_KEY`
   secret of a GitHub environment named `hex`. Restrict that environment
   to `v*` tags, and add a required reviewer if you want one.
3. Check the package locally: `gleam export hex-tarball` builds the tarball
   that would be published, and `gleam docs build` builds the docs.

## Each release

Releases are automated with
[release-please](https://github.com/googleapis/release-please); see
[CONTRIBUTING.md](CONTRIBUTING.md#how-releases-happen) for the commit
conventions it reads.

1. Merge the open release PR (`chore(main): release X.Y.Z`). It already
   updates `version` in `gleam.toml`, `sdk_version` in
   `src/docuconf/internal/cue.gleam` and `CHANGELOG.md`. The golden file and
   the example contract do not need regenerating: their comparisons ignore
   `metadata.generator.version`.
2. release-please tags the merge commit `vX.Y.Z` and creates the GitHub
   release with the changelog entries.
3. The workflow checks that the tag matches `gleam.toml`, runs the tests on
   both targets (including `cue vet` against the docuconf-go meta-schema),
   then runs `gleam publish --yes`.

If the release PR was created with `GITHUB_TOKEN` (no release GitHub App
configured), the tag does not trigger `release.yml` by itself, so
`.github/workflows/release-please.yml` starts it with `gh workflow run`. To
redo a release by hand: `gh workflow run release.yml --ref vX.Y.Z`.

`gleam publish --replace` can replace the latest release within Hex's
grace period. After that, retire a bad release on hex.pm instead.

## docuconf-go version

The spec, the CUE meta-schema and the shared conformance suite live in
[docuconf-go](https://github.com/Docuconf/docuconf-go). `.github/docuconf-go.ref` holds the full docuconf-go commit SHA
this SDK is tested against.

- **Push and pull request CI** check out docuconf-go at that commit, so a change in docuconf-go never breaks this
  repository's CI by surprise.
- **Bump pull requests.** `.github/workflows/docuconf-go-bump.yml` opens (or updates) a
  `build(deps): bump docuconf-go to <sha>` pull request on the `docuconf-go-bump` branch whenever docuconf-go's `main`
  moves: on a `docuconf-go-updated` dispatch from docuconf-go, and daily as a catch-up. CI on that pull request is the
  compatibility check; merge it when it is green. Run the workflow by hand (optionally with a `sha`) to pin a
  specific commit.
- **Nightly.** CI also runs every night against docuconf-go `main`, and can be started by hand with a
  `docuconf_go_ref` input to try any branch or commit.
- **`scripts/conformance.sh`** runs just the shared conformance suite and the `cue vet` tests against a docuconf-go
  checkout: `DOCUCONF_GO_DIR=../docuconf-go scripts/conformance.sh`. docuconf-go runs it on every pull request that
  touches the spec, so a breaking spec change shows up there before it merges.

Without the release GitHub App (`RELEASE_APP_ID` and `RELEASE_APP_PRIVATE_KEY`), the bump pull request is created with
`GITHUB_TOKEN`, which starts no workflows, so the bump workflow starts CI on the branch itself. That needs
**Settings → Actions → General → Allow GitHub Actions to create and approve pull requests**.

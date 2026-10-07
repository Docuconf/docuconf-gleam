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

1. Update `version` in `gleam.toml` and `sdk_version` in
   `src/docuconf/internal/cue.gleam` (written into every exported contract
   as `metadata.generator.version`), then regenerate the golden file:
   `UPDATE_GOLDEN=1 gleam test`.
2. Commit, tag and push:
   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```
3. The workflow checks that the tag matches `gleam.toml`, runs the tests on
   both targets (including `cue vet` against the docuconf-go meta-schema),
   then runs `gleam publish --yes`.

`gleam publish --replace` can replace the latest release within Hex's
grace period. After that, retire a bad release on hex.pm instead.

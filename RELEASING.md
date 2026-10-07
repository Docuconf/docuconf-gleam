# Releasing

The package is published to [Hex](https://hex.pm/packages/docuconf) with
`gleam publish`, by `.github/workflows/release.yml` when a `v*` tag is
pushed. Docs go to HexDocs at the same time.

Note: the Elixir SDK (docuconf-elixir) is also named `docuconf` on Hex.
Hex has one namespace for Erlang, Elixir and Gleam packages, so the two
cannot both be published as `docuconf`. Decide on the names before the
first release, for example `docuconf` for Elixir and `docuconf_gleam` for
Gleam (change `name` in `gleam.toml`; the module names can stay).

## Before the first release

1. **Settle the package name** (see the note above).
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

## GitHub Packages and Releases

GitHub Packages has no Hex registry, so the GitHub copy of each release is the
GitHub Release. The `github` job in `.github/workflows/release.yml` runs on
the same `v*` tags, repeats the tag check and the tests on both targets,
builds the package with `gleam export hex-tarball`, creates the GitHub
Release for the tag if it does not exist, and attaches
`docuconf-<version>.tar`, the tarball Hex would get.

It does not depend on the Hex `publish` job, so it works before the Hex
account, API key and `hex` environment exist. It uses only the workflow's own
`GITHUB_TOKEN` (`contents: write`); there are no secrets or accounts to set
up, and nothing to configure beyond the `Docuconf` organization allowing
`GITHUB_TOKEN` write access (it does unless restricted under Organization
settings > Actions).

### Installing from a GitHub Release

No token is needed for a public repository. Gleam installs from git, so the
simplest way to use a release without Hex is the tag itself, in `gleam.toml`:

```toml
[dependencies]
docuconf = { git = "https://github.com/Docuconf/docuconf-gleam", ref = "v0.1.0" }
```

To use the released tarball, unpack it and depend on the directory:

```sh
curl -sSLO https://github.com/Docuconf/docuconf-gleam/releases/download/v0.1.0/docuconf-0.1.0.tar
mkdir -p vendor/docuconf && tar -xOf docuconf-0.1.0.tar contents.tar.gz | tar -xzf - -C vendor/docuconf
```

```toml
[dependencies]
docuconf = { path = "vendor/docuconf" }
```

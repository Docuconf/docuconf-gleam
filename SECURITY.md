# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately, through GitHub's private vulnerability reporting: open the repository's
**Security** tab and choose **Report a vulnerability**
([direct link](https://github.com/docuconf/docuconf-gleam/security/advisories/new)). Do not open a public issue, pull
request or discussion for a suspected vulnerability.

Include what you can of:

- the affected version of `docuconf_gleam`, the target (Erlang or JavaScript) and the Gleam, Erlang/OTP or Node.js
  version;
- what an attacker can do, and what they need first;
- steps or a minimal declaration, contract, environment or file that reproduces it.

We work on the fix in a private security advisory, credit you in it unless you prefer otherwise, and publish the
advisory when a fixed release is out.

## Response targets

| | |
|---|---|
| Acknowledge the report | within 3 business days |
| First assessment (confirmed or not, severity) | as soon as we can reproduce it, and we keep you updated in the advisory |
| Fix | released as a patch to the supported version, then the advisory is published |

## Supported versions

The package is released as `docuconf_gleam` (see [RELEASING.md](RELEASING.md)). Security fixes go to the latest
release, as a new patch release:

| Artifact | Tag | Supported |
|---|---|---|
| Gleam SDK (`docuconf_gleam`) | `v*` | latest release |

**During the beta, only the latest release is supported.** Upgrade to it to get a fix.

## Scope

In scope: the Gleam SDK in [`src`](src), on both targets, for example a secret value that reaches an error message,
a boot warning, the termination log or `string.inspect`, a value that passes the SDK's checks but should not, or a
file input (certificate, keystore, config file) that is accepted when it should be rejected.

Out of scope: the example application under [`examples`](examples), vulnerabilities in dependencies that docuconf does
not make reachable (report those upstream), and issues in a platform or cluster that only arise from its own
misconfiguration. The CLI, the Helm chart and the CUE meta-schema live in
[docuconf-go](https://github.com/docuconf/docuconf-go) and follow its policy; other language SDKs live in their own
repositories and follow their own.

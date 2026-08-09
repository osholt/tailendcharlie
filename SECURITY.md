# Security policy

## Supported versions

Tail End Charlie has not reached a public release. Only the latest `main` branch is
currently maintained.

## Reporting a vulnerability

Please do not open a public issue for a vulnerability that could expose rider
locations, ride invitation secrets, or emergency details. Report it privately
through GitHub's security-advisory feature for this repository.

The current application is a development preview and must not be relied on for
emergency response.

## Dependency advisories

Every pull request is scanned for dependencies with known advisories:

- **Python** — `pip-audit` in `.github/workflows/server.yml`, over the relay's
  locked environment.
- **Android/Gradle** — `.github/workflows/android-dependencies.yml` submits the
  *resolved* Gradle dependency graph, including the transitive coordinates that
  arrive through Flutter plugins, and fails a pull request that introduces a
  coordinate with a moderate or higher advisory.

The Android scanning depends on the repository's dependency graph and Dependabot
alerts being enabled under Settings -> Code security. Both are free on a public
repository. With them off, the submission has nowhere to go and the review
degrades to reporting nothing rather than to failing loudly — so if that job is
ever green while Dependabot is disabled, it is not evidence of anything.

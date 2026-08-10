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
  arrive through Flutter plugins, which puts them under Dependabot alerts.

The Android scanning depends on the repository's dependency graph and Dependabot
alerts being enabled under Settings -> Code security. Both are free on a public
repository. With them off, the submission has nowhere to go — so a green job is
not on its own evidence that anything was scanned.

The pull-request gate that *fails* a change introducing a vulnerable coordinate
is still outstanding under #395. It compares the base and head dependency
graphs, so it only became possible once `main` carried a Gradle snapshot to
compare against.

### What the Android alerts cover, and what they deliberately do not

The submitted Gradle graph is restricted to the **runtime classpaths**, so a
Dependabot alert on this repository means "an advisory in code we ship".

It was not always so. A Gradle build resolves the app's own dependencies and the
Android Gradle Plugin's, and the submitted snapshot cannot distinguish them —
`gradle/actions` documents that scope assignment "does not yet exist". The first
submission therefore raised 47 alerts of which **44 were AGP's own build-time
transitives**, including the single critical and all 18 highs, while the only
coordinate that reaches a phone sat among them as two moderates. An alert list
that is 94% unactionable is one nobody reads, which is the same failure #393 was
about in a different guise.

**Build-tool exposure is therefore managed by keeping the Android Gradle Plugin
current, not by per-coordinate alerts.** That is a deliberate trade with a real
cost: a compromised build dependency would not raise an alert here. It is
recorded so the next person meets a decision rather than a gap.

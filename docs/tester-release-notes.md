# Tester release notes

One section per tester build, newest first, keyed by the **build number** the
app shows under **Settings → About & build**. Testers reach this file from
**What changed in this build** on that screen.

Android build numbers are Play version codes and come from the
`Android internal testing` workflow's run number (or its `build_number` input).
iOS build numbers come from the `TestFlight` workflow the same way, so the two
platforms do not share a numbering sequence - always say which platform a build
number belongs to.

## How to add an entry

The `Android internal testing` workflow prints a draft (version, build number,
track, commit, run link and recent commits) to its **run summary** and uploads
it as the `tailendcharlie-tester-release-notes` artefact. Copy the tester-facing
parts into a new section here, newest first, using the template below, then
commit it. Nothing publishes automatically - the workflow has read-only
repository permissions by design.

```markdown
## Android build <version-code> — <version> — <date>

### What to test

1. ...

### Fixed

- ...

### Known limitations

- ...
```

## Unreleased

Changes merged but not yet in a tester build.

- Builds now report their real version and build number to the relay instead of
  the hardcoded `1.0.1+22` fallback, so a bug report can be matched to code.
- New **Settings → About & build** screen showing app version, build number,
  distribution track, build date, relay host and last relay sync, with a
  one-tap copy for bug reports.
- Non-blocking "a newer tester build is probably available" prompt on the home
  screen with a direct route to the Play internal-testing listing (TestFlight on
  iOS). The hard **App update required** gate is unchanged.
- New tester guide: [tester-update-guide.md](./tester-update-guide.md).

## Earlier

Before this file existed, tester notes were published as dated documents:

- [23 July 2026](./tester-release-2026-07-23.md)

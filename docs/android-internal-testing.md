# Android internal testing

Tail End Charlie's immediate Android beta channel is Google Play's `internal`
testing track, fed by a manual `Android internal testing` GitHub Actions workflow -
the Android equivalent of [the TestFlight workflow](./server-runbook.md).

Testers do not need this document. Send them
[the tester update guide](./tester-update-guide.md) instead, which covers
joining internal testing, why Play may show no update immediately, how to force
a check, how to read a build number, and how to report which build a bug is on.

## One-time external setup

These steps happen outside this repository and are release gates for the
first upload:

1. **Confirm the package name.** It's `app.tailendcharlie` - the Play Store
   listing must be created under this exact package, since it cannot change
   after the first upload.
2. **Create the app in Google Play Console** and enrol it in
   [Play App Signing](https://support.google.com/googleplay/android-developer/answer/9842756).
   Google then holds the final signing key; the workflow only ever handles
   the *upload* key below.
3. **Generate a dedicated upload keystore** (never commit it):
   ```bash
   keytool -genkeypair -v -keystore upload-keystore.jks \
     -alias tailendcharlie-upload -keyalg RSA -keysize 2048 -validity 10000
   ```
   Back this file up somewhere durable and encrypted - if it's lost before
   Play App Signing has a copy, Google support can reissue an upload key, but
   it's a real disruption to avoid.
4. **Create a least-privilege Google Play service account**, in three parts
   that are easy to think are one step but aren't:
   a. Create the service account itself in Google Cloud Console (IAM & Admin
      -> Service Accounts; Play Console's Setup -> API access page links
      here) and download its JSON key.
   b. **Enable the Android Publisher API** on that same Google Cloud project
      (`console.developers.google.com/apis/api/androidpublisher.googleapis.com/overview?project=<id>`) -
      it's off by default, and the upload step fails clearly but only at
      upload time if it's missed. Allow a few minutes for it to propagate.
   c. **In Play Console itself**, go to Users and permissions, invite the
      service account's email (the JSON key's `client_email`) as a new
      user scoped to this app only, and grant **"Release apps to testing
      tracks"**. Creating the account in Google Cloud grants it no Play
      Console access by itself - skipping this produces a distinct
      "The caller does not have permission" upload failure, propagates
      quickly (no email-acceptance step like a human invite), but is easy
      to miss since nothing in Google Cloud's UI mentions it.
5. **Create the protected `android-internal` GitHub environment** (Settings
   -> Environments) with these repository secrets:
   - `ANDROID_KEYSTORE_BASE64` - `base64 -i upload-keystore.jks | pbcopy`
   - `ANDROID_KEYSTORE_PASSWORD`
   - `ANDROID_KEY_ALIAS`
   - `ANDROID_KEY_PASSWORD`
   - `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` - the full JSON key content
6. **Add the initial tester list** in Play Console's internal testing track
   and publish the opt-in URL to testers, together with
   [the tester update guide](./tester-update-guide.md).
7. **Run the workflow once and verify**: install through the opt-in link on
   a physical Android phone, not just the emulator. Then confirm on that phone
   that **Settings → About & build** shows the same build number the workflow
   uploaded, that **Open Google Play listing** lands on the internal-testing
   page for `app.tailendcharlie`, and that the relay's access log shows that
   build number in `x-tailendcharlie-app-build`. None of those three can be
   verified from CI - they need Play Console access and a real phone.

## Repository behaviour

`apps/mobile/android/app/build.gradle.kts` reads signing material from
`android/key.properties` (git-ignored, absent on every local checkout).
Without it, release builds silently fall back to the debug key - a plain
`flutter build appbundle --release` locally never fails and never touches
real signing material. The GitHub Actions workflow is the only place
`key.properties` gets created, from the secrets above, in `$RUNNER_TEMP`.

Version codes come from `inputs.build_number` or, by default,
`github.run_number` - the same monotonic-by-construction source the
TestFlight workflow uses for iOS build numbers, so they never collide or go
backwards.

The optional `Promote Android testing release` workflow copies an existing
version from `internal` to a closed `alpha` or `beta` track. Promotion must
leave the source release active: the existing internal cohort and a closed
tester group can be configured independently, and removing the internal
release can otherwise leave those testers with no available update even
though the promotion workflow succeeded. Promotion reuses the existing
artefact and never rebuilds, so a promoted build keeps reporting the track it
was *built* for (`Play internal testing`) rather than the track it now sits on.
That is deliberate - the reported track identifies the binary, and a promoted
binary is byte-for-byte the internal one.

## Build identity

`RelayClientDescriptor.current()` and the in-app **About & build** screen both
read the same `--dart-define` values, and
`apps/mobile/test/services/build_identity_test.dart` fails if the two ever
disagree. Every build channel must stamp them in, or the app falls back to the
hardcoded `1.0.1+22` in `internet_relay_client.dart` and every diagnostic,
support conversation and bug report becomes ambiguous about which code it
describes.

`tools/build-identity.sh <pubspec> <track> [build-number]` derives them from
`pubspec.yaml` plus the build number, and every workflow calls it and appends
the result to `$GITHUB_ENV`:

| Define | Source | Purpose |
| --- | --- | --- |
| `RIDE_RELAY_APP_VERSION` | `version:` in `apps/mobile/pubspec.yaml` | Marketing version; also passed as `--build-name` so the artefact and the reported value cannot drift. |
| `RIDE_RELAY_APP_BUILD` | `inputs.build_number` or `github.run_number` | The Play version code / iOS build number. Unchanged monotonic scheme. |
| `RIDE_RELAY_DISTRIBUTION_TRACK` | `internal`, `testflight`, `ci`, or `local` | What the About screen shows as the distribution track. |
| `RIDE_RELAY_BUILD_TIMESTAMP` | build time, UTC ISO-8601 | Drives the non-blocking "a newer tester build is probably available" prompt. |
| `RIDE_RELAY_TESTER_NOTES_URL` | repository URL at the built commit | **What changed in this build** on the About screen. |
| `RIDE_RELAY_TESTER_UPDATE_URL` | `RIDE_RELAY_TESTFLIGHT_INVITE_URL` repository variable (iOS only, optional) | Overrides the default store destination. Set it to the public TestFlight invitation link once App Store Connect has issued one; unset, iOS falls back to `https://testflight.apple.com/`. |

Prove the plumbing locally without waiting on a store upload:

```bash
set -a; eval "$(tools/build-identity.sh apps/mobile/pubspec.yaml internal 4242)"; set +a
cd apps/mobile
flutter test test/services/build_identity_test.dart \
  --dart-define=RIDE_RELAY_APP_VERSION="$RIDE_RELAY_APP_VERSION" \
  --dart-define=RIDE_RELAY_APP_BUILD="$RIDE_RELAY_APP_BUILD" \
  --dart-define=RIDE_RELAY_DISTRIBUTION_TRACK="$RIDE_RELAY_DISTRIBUTION_TRACK" \
  --dart-define=RIDE_RELAY_BUILD_TIMESTAMP="$RIDE_RELAY_BUILD_TIMESTAMP" \
  --dart-define=RIDE_RELAY_API_BASE_URL=https://relay.tailendcharlie.app/api
```

The guarded test prints the resolved identity and asserts that the relay
headers carry it:

```
stamped build identity: Tail End Charlie 1.0.1+4242 · Play internal testing ·
android · built 2026-07-25 22:28:51.000Z · relay relay.tailendcharlie.app
```

Without the defines that test is skipped and the unstamped fallback is asserted
instead, so plain `flutter test` still passes.

The relay receives the same values as `x-tailendcharlie-app-version` and
`x-tailendcharlie-app-build` on every request. The relay does not currently log
or store them, so confirming them for a real upload means reading the reverse
proxy's access log (see [server-runbook.md](./server-runbook.md)) rather than
querying the relay.

## Release cadence and tester notes

`Android internal testing` writes a release summary - version, build number,
track, build timestamp, commit, run link and the recent commits on the ref - to
the workflow run summary, and uploads it as the
`tailendcharlie-tester-release-notes` artefact. Copy the tester-facing parts
into [tester-release-notes.md](./tester-release-notes.md) so a build number maps
to changes; the workflow keeps `contents: read` and never commits or tags
anything itself.

## Triggering a beta

```bash
gh workflow run "Android internal testing" --ref <branch>
```

Needs the `RIDE_RELAY_API_BASE_URL` repository variable set first (see
[server-runbook.md](./server-runbook.md)) - the build fails clearly if it's
missing, the same as TestFlight.

## Local fallbacks

Two options exist for a quick check without waiting on a Play Store upload
and its review/propagation delay:

- **Android Emulator**: `flutter run` against any AVD is the fastest
  iteration loop and needs no signing or Play Console access at all.
- **Firebase App Distribution**: a lighter-weight alternative to Play
  internal testing when testers just need a signed build fast (no Play
  Console review, install links usually work within minutes). Not wired up
  in this repository - `flutter build apk --release` plus the
  [Firebase CLI's `appdistribution:distribute`](https://firebase.google.com/docs/app-distribution/android/distribute-cli)
  command is the manual path if this becomes useful before Play internal
  testing is fully live.

# Android internal testing

Tail End Charlie's Android testers are on Google Play's **closed `alpha`**
track. A release reaches them in one manual `Android internal testing` run: it
uploads the App Bundle to `internal` and then promotes it to the closed track
named by the `promote_to` input. `internal` remains the upload track and keeps
its own cohort; `alpha` is where the tester group is.

Testers do not need this document. Send them
[the tester update guide](./tester-update-guide.md) instead, which covers
joining closed testing, why Play may show no update immediately, how to force
a check, how to read a build number, and how to report which build a bug is on.

Two things this pipeline used to get wrong, both from the #101 delivery
investigation, both fixed in #122:

- Promotion was a separate manual workflow, and it was missed: version code 24
  was uploaded to `internal` on 24 July 2026 and never promoted, so no closed
  tester ever received it while the run showed green. `promote_to` now promotes
  in the same run, and the run summary states in plain words whether closed
  testers can install the build.
- Every build was stamped `internal`, so the About screen told `alpha` testers
  they were on internal testing and its update button opened the public store
  listing, which does not offer the app to a closed tester who has not opted in.
  The build is now stamped with the track it is *destined* for.

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
6. **Add the tester list to the closed `alpha` track** in Play Console and
   publish its opt-in URL - `https://play.google.com/apps/testing/app.tailendcharlie` -
   to testers, together with [the tester update guide](./tester-update-guide.md).
   Keep the `internal` track's own tester list if you use it; promotion leaves
   the internal release active.
7. **Run the workflow once with `promote_to: alpha` and verify**: install
   through the opt-in link on a physical Android phone, not just the emulator.
   Then confirm on that phone that **Settings → About & build** shows the same
   build number the workflow uploaded and `Play closed testing (alpha)` as the
   distribution track, that **Open closed testing page** lands on the
   `apps/testing` opt-in page for `app.tailendcharlie`, and that the relay's
   access log shows that build number in `x-tailendcharlie-app-build` and
   `alpha` in `x-tailendcharlie-distribution-track`. None of those can be
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

## Promotion

`Android internal testing` takes a `promote_to` input - `alpha` (default),
`beta`, or `none`:

- `alpha`/`beta`: the App Bundle is uploaded to `internal`, then promoted with
  `fastlane supply --track internal --track_promote_to <track>`. The build is
  also *stamped* with that track, so the About screen and the relay headers name
  the track testers install from.
- `none`: upload only. Nothing reaches a closed tester, and the run summary says
  so rather than reporting a bare success.

Promotion leaves the source release active (`--deactivate_on_promote false`):
the internal cohort and the closed tester group are configured independently, and
deactivating the source can leave internal testers with no available update even
though promotion succeeded.

`Promote Android testing release` remains, for re-promoting a version code that
is already in Play - after a rollback, or onto a second closed track. It sends no
tester email: it cannot know which commit an arbitrary version code was built
from, and a notification that guesses the commit is worse than none.

Promotion reuses the uploaded artefact and never rebuilds. That is exactly why
the destined track has to be stamped at build time - the only alternative is a
binary that describes a track its testers cannot see.

## Build identity

`RelayClientDescriptor.current()` and the in-app **About & build** screen both
read the same `--dart-define` values, and
`apps/mobile/test/services/build_identity_test.dart` fails if the two ever
disagree. Every build channel must stamp them in, or the app reports its version
and build number as `unknown` and its track as `Local build` -
`RelayClientDescriptor` deliberately maps an absent or malformed define to
`unknown` rather than a plausible-looking constant, because a wrong version makes
every version-conditional diagnostic silently misleading. A local device build
has to stamp them too; see
[build-and-run.md](./build-and-run.md#what-a-device-build-must-have-stamped-in).

`tools/build-identity.sh <pubspec> <track> [build-number]` derives them from
`pubspec.yaml` plus the build number, and every workflow calls it and appends
the result to `$GITHUB_ENV`:

| Define | Source | Purpose |
| --- | --- | --- |
| `RIDE_RELAY_APP_VERSION` | `version:` in `apps/mobile/pubspec.yaml` | Marketing version; also passed as `--build-name` so the artefact and the reported value cannot drift. |
| `RIDE_RELAY_APP_BUILD` | `inputs.build_number` or `github.run_number` | The Play version code / iOS build number. Unchanged monotonic scheme. |
| `RIDE_RELAY_DISTRIBUTION_TRACK` | `alpha`, `beta`, `internal`, `testflight`, `ci`, or `local` - the track the build is *destined for* | What the About screen shows as the distribution track, which store page its update button opens, and the `x-tailendcharlie-distribution-track` relay header. |
| `RIDE_RELAY_BUILD_TIMESTAMP` | build time, UTC ISO-8601 | Drives the non-blocking "a newer tester build is probably available" prompt. |
| `RIDE_RELAY_TESTER_NOTES_URL` | repository URL at the built commit | **What changed in this build** on the About screen. |
| `RIDE_RELAY_TESTER_UPDATE_URL` | `RIDE_RELAY_TESTFLIGHT_INVITE_URL` repository variable (iOS only, optional) | Overrides the default store destination. Set it to the public TestFlight invitation link once App Store Connect has issued one; unset, iOS falls back to `https://testflight.apple.com/`. |

The track drives the Android update destination: `alpha`/`beta` open
`https://play.google.com/apps/testing/app.tailendcharlie`, anything else opens
the store listing. `RIDE_RELAY_TESTER_UPDATE_URL` still overrides both.

Prove the plumbing locally without waiting on a store upload:

```bash
set -a; eval "$(tools/build-identity.sh apps/mobile/pubspec.yaml alpha 4242)"; set +a
cd apps/mobile
flutter test test/services/build_identity_test.dart \
  --dart-define=RIDE_RELAY_APP_VERSION="$RIDE_RELAY_APP_VERSION" \
  --dart-define=RIDE_RELAY_APP_BUILD="$RIDE_RELAY_APP_BUILD" \
  --dart-define=RIDE_RELAY_DISTRIBUTION_TRACK="$RIDE_RELAY_DISTRIBUTION_TRACK" \
  --dart-define=RIDE_RELAY_BUILD_TIMESTAMP="$RIDE_RELAY_BUILD_TIMESTAMP" \
  --dart-define=RIDE_RELAY_API_BASE_URL=https://relay.tailendcharlie.app/api
```

Two guarded tests then run instead of being skipped. The first prints the
resolved identity and asserts the relay headers carry it; the second pumps the
real About sheet and asserts the stamped track reaches both the screen and the
headers:

```
stamped build identity: Tail End Charlie 1.0.1+4242 · Play closed testing
(alpha) · android · built 2026-07-26 09:14:02.000Z · relay
relay.tailendcharlie.app
stamped track: Play closed testing (alpha) · header alpha · update
https://play.google.com/apps/testing/app.tailendcharlie
```

Without the defines both are skipped and the unstamped fallback is asserted
instead, so plain `flutter test` still passes.

The relay receives the same values as `x-tailendcharlie-app-version`,
`x-tailendcharlie-app-build` and `x-tailendcharlie-distribution-track` on every
request. The relay does not currently log or store them, so confirming them for
a real upload means reading the reverse proxy's access log (see
[server-runbook.md](./server-runbook.md)) rather than querying the relay.

## Release cadence and tester notes

`Android internal testing` writes a release summary - version, build number,
stamped track, build timestamp, commit, run link, whether closed testers can
install it, and the recent commits on the ref - to the workflow run summary, and
uploads it as the `tailendcharlie-tester-release-notes` artefact. Copy the
tester-facing parts into [tester-release-notes.md](./tester-release-notes.md) so
a build number maps to changes; the workflow keeps `contents: read` (plus
`actions: read`, to find the previous release's commit) and never commits or tags
anything itself.

## Notifying the closed tester group

After a *successful promotion*, the workflow runs
`tools/tester_notify/notify_testers.py`, which renders one plain-text email:
version, build number, platform and track, the commit it was built from, what
changed since the previous released build, the closed-testing opt-in link, and
the three values **Settings → About & build** must show afterwards. The mail is
rendered into the run summary on every release, sent or not.

There is no iOS equivalent, deliberately: TestFlight already notifies its own
testers when a build arrives, and a second mail for the same release is noise.

The closed testers are the Google Group
**`tail-end-charlie-testers@googlegroups.com`**
([group](https://groups.google.com/g/tail-end-charlie-testers)). That address
lives in the `RIDE_RELAY_ANDROID_TESTER_GROUP` repository variable, never in a
committed file, so it can change without a code change.

Configuration, all optional - with none of it set the step renders and skips:

| Kind | Name | Purpose |
| --- | --- | --- |
| Variable | `RIDE_RELAY_ANDROID_TESTER_GROUP` | The closed-tester group address - `tail-end-charlie-testers@googlegroups.com`. **Unset means dry run** - the mail is rendered into the summary and nothing is sent. The tool never guesses a recipient, and refuses anything that is not one plain address. |
| Variable | `RIDE_RELAY_TESTER_NOTIFY_FROM` | The From address. |
| Variable | `RIDE_RELAY_TESTER_NOTIFY_SMTP_HOST` | SMTP host. |
| Variable | `RIDE_RELAY_TESTER_NOTIFY_SMTP_PORT` | SMTP port; defaults to 587 (STARTTLS). 465 uses implicit TLS. Plaintext SMTP is never attempted. |
| Secret | `RIDE_RELAY_TESTER_NOTIFY_SMTP_USERNAME` | SMTP username. |
| Secret | `RIDE_RELAY_TESTER_NOTIFY_SMTP_PASSWORD` | SMTP password or app password. Never appears in the summary or the log. |

Behaviour that the unit tests in `tools/tester_notify/tests/` pin down:

- No recipient, or an incomplete sending identity: a `::notice::` naming exactly
  what is missing, the full mail in the summary, exit 0.
- `notification_mode: dry-run`: renders and sends nothing even when fully
  configured.
- A delivery failure: `::error::` annotation, exit 0. The step is also
  `continue-on-error`, so a mail problem can never fail a release.
- Only store and repository links may appear in the mail. The relay base URL,
  which can carry a path or a token, is rejected before anything is sent - even
  if it arrives through a commit subject in the changelog.
- The summary masks the group address (`t***@example.com`); this repository is
  public and its run summaries are public with it.

### Two things that fail silently, and neither is visible from CI

1. **The sending identity must be allowed to post to the group.** If
   `tail-end-charlie-testers@googlegroups.com` only accepts posts from members
   and `RIDE_RELAY_TESTER_NOTIFY_FROM` is not one, Google rejects the message or
   holds it for moderation. The workflow sees a successful SMTP handover and
   reports success. Add the sending identity to the group with posting rights,
   or allow that specific address to post, and confirm the first real send
   actually landed in the group's archive.
2. **The group and Play Console's `alpha` tester list must be the same people.**
   Play grants install access from whatever list the closed track is configured
   with; the mail goes to this group. If the two diverge, the mail either
   reaches people who cannot install the build or misses people who can. Nothing
   in this repository can compare them - check both by hand whenever either
   changes.

To see the mail without configuring anything, run the tool directly:

```bash
git log --no-merges --max-count=5 --pretty='- %s (%h)' > /tmp/changes.md
python3 tools/tester_notify/notify_testers.py \
  --track alpha --app-version 1.0.1 --build-number 31 \
  --commit "$(git rev-parse HEAD)" --repository osholt/tailendcharlie \
  --run-url https://github.com/osholt/tailendcharlie/actions/runs/1 \
  --changes-file /tmp/changes.md --changes-baseline 'build 28' \
  --recipient '' --mode auto
```

## Triggering a beta

```bash
gh workflow run "Android internal testing" --ref <branch> \
  --field promote_to=alpha --field notification_mode=auto
```

`promote_to` defaults to `alpha` and `notification_mode` to `auto`, so a plain
`gh workflow run "Android internal testing" --ref <branch>` uploads, promotes to
the closed track and notifies. Use `--field notification_mode=dry-run` for the
first run after configuring the group, to read the mail before anyone else does.

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
  command is the manual path if this becomes useful before Play closed
  testing is fully live.

## What cannot be verified from CI

Nothing in this repository can observe Google Play. These need Play Console
access, and the last two need a physical Android phone on the tester list:

- That the closed `alpha` track has the intended testers, and that its release
  shows as `completed` rather than draft or in-review.
- That the `alpha` tester list and `tail-end-charlie-testers@googlegroups.com`
  hold the same people, and that the sending identity may post to the group.
  Both fail silently, and both are outside this repository.
- That the promotion in a given run actually moved the version code to `alpha`
  in Play - the workflow reports `fastlane supply`'s exit status, which is
  evidence of the API call succeeding, not of what a tester's Play app offers.
- That `https://play.google.com/apps/testing/app.tailendcharlie` offers the new
  build to an opted-in account, and how long Play takes to do so.
- That **About & build** on the installed build shows the version, build number
  and track the release email quotes.

The email itself has never been sent from this repository. The first real send
is a maintainer decision: configure the variables, run once with
`notification_mode: dry-run`, read the rendered mail in the run summary, and only
then switch to `auto`.

## Managed publishing will silently strand testers

**Managed publishing must stay off.** With it on, every track change the API
commits sits in a Console queue until a human clicks **Publish**, and nothing in
the pipeline can tell:

- `fastlane supply` exits 0.
- The Play Developer API reports the release `status: completed` on the track.
- Testers keep whatever was last published, indefinitely.

That happened. Version code 29 was uploaded to `internal` and promoted to
`alpha` on 27 July 2026, both reported success, and the closed testers' opt-in
page still offered a build from **21 July** — the date of the last manual
publish. The queue held two changes: the `alpha` promotion nobody had published,
and a stale open-testing release from the previous week.

It is off now. If it is ever turned back on, every tester release needs a Console
publish, and the CI reporting is not evidence that testers got anything.

### Checking what testers actually have

Run the **Play track status** workflow. It lists every track with its release
name, status and version codes, so the question "what have testers actually got?"
is answerable without opening the Console:

```bash
gh workflow run "Play track status" --ref main
```

It is read-only: it opens an edit to list the tracks and always deletes it.

Two details that cost time when this was first written:

- The Play service account is an **environment** secret on `android-internal`,
  not a repository secret. A workflow that omits `environment: android-internal`
  reads it as an empty string.
- Version codes must increase monotonically and the tracks are already well ahead
  of `github.run_number`, so pass `build_number` explicitly on every release.
  Without it the upload is rejected for not letting existing users upgrade.

### Track names

The Console's labels and the API's track ids do not match, which matters when
choosing where a build goes:

| Console | API track |
| --- | --- |
| Internal testing | `internal` |
| Closed testing - Alpha | `alpha` |
| Open testing | `beta` |
| Production | `production` |

Closed testers are on `alpha`. `beta` is open testing — public, anyone may join.
Do not promote to `beta` expecting it to reach the closed group.

## Open testing was live by accident

`beta` was believed to be paused on an old release. It was not: on 27 July 2026
the API reported it `completed` on version code **7** while closed testing was on
30, which means the app was generally available to anyone with the link, running a
build from weeks earlier.

The likely cause is the same managed-publishing queue described above. Turning
managed publishing off released everything that had been queued — including the
stale open-testing release nobody had published. Turning the trap off published
the thing the trap was holding back.

Two lessons:

- **Never infer a track's state.** Run `Play track status`; the Console's
  "paused" wording and the API's `status` are not the same thing, and a belief
  written into a document outlives the state it described. This document said
  "paused" and that is what stopped anyone looking.
- **Check every track after changing publishing settings**, not just the one you
  were promoting to.

### Closing a public track

```bash
gh workflow run "Close public Play tracks" --ref main \
  -f confirm=close-public-tracks \
  -f halt_open_testing=true \
  -f delete_production_draft=false
```

It never touches `internal` or `alpha`, and it refuses to touch a non-draft
production release — withdrawing a live production release is a separate,
deliberate decision. Every change is verified by reading the track back, because
a committed edit is not evidence that anything changed.

**Deleting a draft production release works. Stopping open testing does not.**
The Play Developer API has no way to withdraw a *completed* open-testing release,
and all three plausible mechanisms were tried against the live track on
27 July 2026:

| Mechanism | Result |
| --- | --- |
| `status: halted` | `500 Internal error` on commit — `halted` is a staged-rollout state |
| `releases: []` | commit succeeds, **track keeps serving the same release** |
| `status: draft` | commit succeeds, adds a draft *beside* the live release, which keeps serving |

The second and third are the dangerous ones: they report success. That is why the
workflow verifies rather than trusting `commit`.

**Open testing can only be stopped in the Play Console:** Testing → Open testing
→ **Pause track**. There is no API equivalent. Run `Play track status` afterwards
to confirm `beta` no longer reports `completed`.

# Build and run

Read this before your first build, not after the first failure. Every trap in
the [symptom index](#symptom-index) was hit in a single local-device evaluation
session on 26 July 2026 by someone with full repository access, and each one
looked like something other than what it was. One produced a launch crash that
was reported to the maintainer as a product bug. Another produced a confident,
wrong conclusion that local signing was broken when it was not.

Companion documents, all of which this one links into rather than duplicates:

- [release-signing.md](./release-signing.md) — signing policy, the CarPlay
  entitlement constraint, TestFlight secrets, certificate and profile facts.
- [android-internal-testing.md](./android-internal-testing.md) — the Play
  closed-track pipeline, build identity, promotion, tester notification.
- [tester-update-guide.md](./tester-update-guide.md) — the tester-facing guide.
- [server-runbook.md](./server-runbook.md) — the relay this build talks to.

## The five rules

0. **Deploy the relay at the same commit as any app build you install.** The app
   and `apps/server` are one system: several fixes live entirely or partly on the
   server, so an app build alone can leave a defect looking unfixed. On 26 July
   the relay sat on a commit two days behind `main` while three app builds were
   installed and tested, and the presence and alert failures that were re-reported
   each time were the undeployed server. Check with
   `ssh <relay-host> 'cd /opt/tailendcharlie && git log --oneline -1'` before
   concluding an app-side fix did not work, and see
   [server-runbook.md](./server-runbook.md) for the deploy.
1. **A build you intend to launch by tapping its icon must be `--profile`.** An
   iOS Flutter *debug* build only runs while Flutter tooling or Xcode is
   attached. Tapping the icon afterwards crashes it. This is iOS policy, not a
   bug in this app.
2. **On iOS, `--release` is not the device configuration here — `--profile`
   is.** Release is wired to an App Store profile that contains no devices.
3. **Never switch the Runner target to automatic signing, and never remove the
   CarPlay entitlement to make a signing error go away.** The first can never
   work for this app; the second makes iOS kill the app at launch.
4. **CI signing is already correct on both platforms.** See
   [The state of signing](#the-state-of-signing). Do not "fix" it.

## Which configuration for which purpose

| Purpose | Configuration | Signing | Notes |
| --- | --- | --- | --- |
| iOS Simulator, day-to-day work | Debug | none required | Hot reload. `make ios-simulator` also spoofs GPS to the demo route. |
| Physical iPhone, debugging with the tooling attached | Debug | `Apple Development` + `Tail End Charlie CarPlay Navigation Development` | Usable **only** while `flutter run` or Xcode stays attached. |
| Physical iPhone, evaluation / a real ride / handing the phone to someone | **Profile** | `Apple Development` + `Tail End Charlie CarPlay Navigation Development` | The device-evaluation configuration. AOT-compiled, launches from the home screen, still exposes DevTools and the timeline. |
| Physical iPhone, release-identical | Release | `Apple Distribution` + `Tail End Charlie CarPlay Navigation App Store` | **Not installable directly.** Go through TestFlight. |
| Android emulator | Debug | local `~/.android/debug.keystore` | Fastest loop; no Play Console access needed. |
| Android phone, evaluation | Debug or Profile | local `~/.android/debug.keystore` | Android has no equivalent of the iOS debug-JIT restriction: an Android debug build *does* launch from the launcher. |
| Android phone, release-like | Release | **falls back to the debug key locally** | `android/key.properties` is git-ignored and absent locally, so a local `--release` build never touches real signing material. |
| CI, every push (`mobile.yml`) | Debug | Android debug certificate; iOS `--no-codesign` | Analysis, tests, a debug APK, and an unsigned iOS `.app`. |
| CI, TestFlight (`testflight.yml`, manual) | Release | `Apple Distribution` `.p12` + `Tail End Charlie CarPlay Navigation App Store` in a temporary keychain | Archives with `xcodebuild`, exports per `ios/ExportOptions-TestFlight.plist`, uploads with `altool`. |
| CI, Play closed track (`android-internal.yml`, manual) | Release | upload keystore from secrets, Play App Signing on Google's side | Uploads to `internal`, promotes to `alpha` in the same run. |

What the iOS project actually says, in
`apps/mobile/ios/Runner.xcodeproj/project.pbxproj`, for the **Runner** target:

| Setting | Debug | Profile | Release |
| --- | --- | --- | --- |
| `CODE_SIGN_STYLE` | `Manual` | `Manual` | `Manual` |
| `CODE_SIGN_IDENTITY` | `Apple Development` | `Apple Development` | `Apple Distribution` |
| `CODE_SIGN_ENTITLEMENTS` | `Runner/DebugProfile.entitlements` | `Runner/DebugProfile.entitlements` | `Runner/Release.entitlements` |
| `PROVISIONING_PROFILE_SPECIFIER` | `Tail End Charlie CarPlay Navigation Development` | `Tail End Charlie CarPlay Navigation Development` | `Tail End Charlie CarPlay Navigation App Store` |
| `DEVELOPMENT_TEAM` | `UY4624PH6X` | `UY4624PH6X` | `UY4624PH6X` |

All three are manual by design. `aps-environment` is `development` in
`DebugProfile.entitlements` and `production` in `Release.entitlements`; both
carry `com.apple.developer.carplay-driving-task`,
`com.apple.developer.carplay-maps`, and
`applinks:tailendcharlie.app`.

## What a device build must have stamped in

A device build with no `--dart-define` values compiles and runs, and is close to
useless: it talks to no relay and cannot say which code it is. Two groups
matter.

**Build identity** — four values, produced by
`tools/build-identity.sh <pubspec> <track> [build-number]`. Since #121 an
unstamped build reports its version and build number as `unknown` rather than a
plausible-looking constant — `RelayClientDescriptor` in
`apps/mobile/lib/internet/internet_relay_client.dart` maps an empty or malformed
define to `unknown`, deliberately, because a wrong version makes every
version-conditional diagnostic silently misleading. An unstamped track shows as
`Local build` on **About & build** and travels to the relay as `unknown`. Use
`RIDE_RELAY_DISTRIBUTION_TRACK=local` for a hand-built device build, which is
what `tools/build-identity.sh … local` produces. The full table of what each
value drives is in
[android-internal-testing.md § Build identity](./android-internal-testing.md#build-identity).

**Relay URL** — `RIDE_RELAY_API_BASE_URL`. Without it,
`InternetRelayConfiguration.fromEnvironment()` yields a null base URI, the app
sends no server traffic at all, and **About & build** shows no relay host. It
must be an absolute HTTPS URL with no query, fragment or credentials. The
deployed relay is `https://relay.tailendcharlie.app/api` (the same default the
`Makefile` uses); see [server-runbook.md](./server-runbook.md).

Optional, and all defaulted — omit them unless you are testing the feature:
`RIDE_RELAY_TESTER_NOTES_URL`, `RIDE_RELAY_TESTER_UPDATE_URL`,
`RIDE_RELAY_TESTER_BUILD_LIFETIME_DAYS`, `RIDE_RELAY_MAP_STYLE_URL` and its dark
counterpart, `RIDE_RELAY_TILE_URL` and the other tile settings (see
[maps-and-gpx.md](./maps-and-gpx.md)), `RIDE_RELAY_DISCOVERY_API_URL`,
`RIDE_RELAY_PUSH_ENABLED` with its Firebase companions (see
[push-notifications.md](./push-notifications.md)). The basemap has a working
public default, so a device build gets a map without configuring anything.

## Before the first build

- **Flutter 3.44.6 / Dart 3.12.2.** CI pins these; use them locally.
  `flutter doctor` should be clean for the platforms you intend to target.
- **iOS**: a Mac with Xcode. Android: JDK 17 and a current Android SDK.
- **There is no `Podfile`.** iOS dependencies come through Swift Package Manager,
  so the first device build sits on `Xcode is fetching Swift Package Manager
  dependencies. This may take several minutes...` for several minutes even with
  a warm cache. That is not a hang. Subsequent builds are much faster.
- **iOS 16 and later require Developer Mode on the phone** before a
  development-signed build will run: **Settings → Privacy & Security →
  Developer Mode**, then reboot. The menu entry only appears once the device has
  been connected to a Mac running Xcode.
- **The phone's UDID must already be in the
  `Tail End Charlie CarPlay Navigation Development` profile.** Registering a
  device and reissuing the profile is an Apple-account action — see
  [Account-bound actions](#account-bound-actions). Do not commit a UDID
  anywhere.

## Commands

All paths are relative to the repository root unless a `cd` says otherwise.

### iOS Simulator

```bash
make ios-simulator
```

Boots against the first already-booted simulator, points the relay at
`https://relay.tailendcharlie.app/api`, and spoofs GPS to the demo route's start
near Bristol. Override either:

### Apple's CarPlay simulator

```bash
tools/carplay-simulator.sh --install apps/mobile/build/ios/iphonesimulator/Runner.app
```

Brings up the head-unit window with the app installed on it, having first built
it with `cd apps/mobile && flutter build ios --simulator --debug`. Tap the app
on the CarPlay home screen to open its map template.

This works, and it stopped working three separate times for three reasons that
all look like "the app is broken" and are not:

- **`I/O → External Displays → CarPlay` acts on Simulator.app's key device
  window.** With no key window every item in that menu is disabled, and a
  scripted click on it is accepted and does nothing. The menu can even show a
  checkmark against CarPlay with no CarPlay window in existence.
- **CoreSimulatorService wedges.** Once it has, `simctl boot` fails with
  `launchd_sim may have crashed or quit responding`, plain `simctl` commands
  hang, and no display can be attached. `killall -9
  com.apple.CoreSimulator.CoreSimulatorService` is the fix, and it has to
  happen before anything else is diagnosed.
- **A device that has been through a wedged service stays broken.** `carkitd`
  receives a session with a null identity and a 0x0 screen, discards it as
  partial, and the CarPlay window stays black for ever. A device created after
  the restart works. The script therefore owns its own device.

Two things that are **not** causes, both of which have been chased:

- The simulator build carries no entitlements at all — `codesign -d
  --entitlements -` on it prints an empty dict — and CarPlay works anyway. The
  `CPTemplateApplicationSceneSessionRoleApplication` scene declaration in
  `Info.plist` is what makes the app eligible there. Do not try to fix a
  CarPlay simulator problem by re-signing the simulator build: `codesign
  --force --sign -` over it produces `EBADEXEC` and SpringBoard then refuses to
  launch the app at all, with or without the CarPlay entitlements.
- The app icon. It renders correctly on the CarPlay launcher from the existing
  `AppIcon` set.

**Tap the head unit by hand.** Synthetic clicks into the CarPlay window
(`CGEventPost`, AppleScript, `cliclick`) work for a while and then silently
stop: the display keeps rendering — its clock still advances — but stops
accepting pointer events, and re-attaching the display does not restore them.
Every remaining symptom then looks like an app fault. If a scripted tap
produces nothing, tap a built-in app such as Settings to prove the input path
before diagnosing anything else, and note the window can also drift off-screen
(a negative `X` in the CoreGraphics window list), which sends every click
somewhere else entirely.

Screenshot the head unit with `simctl`, not `screencapture`:

```bash
xcrun simctl io booted screenshot --display external head-unit.png
```

`screencapture -l <window-id>` of the CarPlay window returns solid black, and a
full-screen capture only works while Simulator.app is frontmost on the current
Space.

```bash
make ios-simulator IOS_SIMULATOR_LOCATION=51.5074,-0.1278
make ios-simulator RIDE_RELAY_API_BASE_URL=https://relay.example.com/api
```

### A physical iPhone — the device-evaluation path

This is the one to follow. The path was exercised end to end on 26 July 2026
with the predecessor Driving Task profile. The navigation replacement was
installed on 29 July and has both local development certificates and both test
devices. A signed Profile build completed on 29 July with both CarPlay
entitlements stamped into `Runner.app`; it still needs a physical CarPlay
head-unit run as navigation-specific runtime evidence.

It needs a Mac with Xcode, the
`Tail End Charlie CarPlay Navigation Development` profile installed locally,
and the matching Apple Development certificate in the login keychain. Check
both first:

```bash
security find-identity -v -p codesigning     # expect an "Apple Development" identity
```

```bash
# Both directories are real. Search both - see the symptom index.
# -a matters: without it, BSD grep -r finds nothing in these binary files.
grep -rla "Tail End Charlie CarPlay Navigation Development" \
  ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/ \
  ~/Library/MobileDevice/Provisioning\ Profiles/ 2>/dev/null
```

Then find the device and run it in **profile** mode:

```bash
flutter devices
```

```bash
set -a; eval "$(tools/build-identity.sh apps/mobile/pubspec.yaml local 9001)"; set +a
cd apps/mobile
flutter run --profile -d <device-id> \
  --build-name="$RIDE_RELAY_APP_VERSION" \
  --build-number="$RIDE_RELAY_APP_BUILD" \
  --dart-define=RIDE_RELAY_APP_VERSION="$RIDE_RELAY_APP_VERSION" \
  --dart-define=RIDE_RELAY_APP_BUILD="$RIDE_RELAY_APP_BUILD" \
  --dart-define=RIDE_RELAY_DISTRIBUTION_TRACK="$RIDE_RELAY_DISTRIBUTION_TRACK" \
  --dart-define=RIDE_RELAY_BUILD_TIMESTAMP="$RIDE_RELAY_BUILD_TIMESTAMP" \
  --dart-define=RIDE_RELAY_API_BASE_URL=https://relay.tailendcharlie.app/api
```

`9001` is an arbitrary local build number; anything that is not a real store
build number will do. Press `q` when you are done — because this is a profile
build, the installed app keeps working and can be relaunched by tapping its
icon.

To install without holding a tooling session open, build and install
separately:

```bash
set -a; eval "$(tools/build-identity.sh apps/mobile/pubspec.yaml local 9001)"; set +a
cd apps/mobile
flutter build ios --profile \
  --build-name="$RIDE_RELAY_APP_VERSION" \
  --build-number="$RIDE_RELAY_APP_BUILD" \
  --dart-define=RIDE_RELAY_APP_VERSION="$RIDE_RELAY_APP_VERSION" \
  --dart-define=RIDE_RELAY_APP_BUILD="$RIDE_RELAY_APP_BUILD" \
  --dart-define=RIDE_RELAY_DISTRIBUTION_TRACK="$RIDE_RELAY_DISTRIBUTION_TRACK" \
  --dart-define=RIDE_RELAY_BUILD_TIMESTAMP="$RIDE_RELAY_BUILD_TIMESTAMP" \
  --dart-define=RIDE_RELAY_API_BASE_URL=https://relay.tailendcharlie.app/api
xcrun devicectl device install app --device <device-id> \
  build/ios/iphoneos/Runner.app
```

Before installing, confirm the artefact is signed the way you expect — this is
faster than diagnosing a rejected install:

```bash
app=build/ios/iphoneos/Runner.app
codesign -dv --verbose=4 "$app" 2>&1 | grep -E "Authority=|TeamIdentifier"
security cms -D -i "$app/embedded.mobileprovision" | plutil -extract Name raw -
codesign -d --entitlements - --xml "$app" | plutil -p -
```

A correct profile build reports `TeamIdentifier=UY4624PH6X`, an
`Apple Development` authority, an embedded profile named
`Tail End Charlie CarPlay Navigation Development`, and entitlements containing
`com.apple.developer.carplay-driving-task`,
`com.apple.developer.carplay-maps`, and
`aps-environment => development`. Note that the `Authority=` line's brackets
carry the **Apple ID's** identifier, not the team — `TeamIdentifier` is the team.

Confirm afterwards, on the phone, that **Settings → About & build** shows
`1.0.1`, build `9001`, `Local build`, and `relay.tailendcharlie.app`. If it
shows `unknown`, the defines did not reach the build.

### An Android phone or emulator

```bash
cd apps/mobile
flutter run -d <device-id>                        # debug; fine on Android
```

For a build that behaves like a tester build, stamp it the same way and use
`--profile`:

```bash
set -a; eval "$(tools/build-identity.sh apps/mobile/pubspec.yaml local 9001)"; set +a
cd apps/mobile
flutter run --profile -d <device-id> \
  --dart-define=RIDE_RELAY_APP_VERSION="$RIDE_RELAY_APP_VERSION" \
  --dart-define=RIDE_RELAY_APP_BUILD="$RIDE_RELAY_APP_BUILD" \
  --dart-define=RIDE_RELAY_DISTRIBUTION_TRACK="$RIDE_RELAY_DISTRIBUTION_TRACK" \
  --dart-define=RIDE_RELAY_BUILD_TIMESTAMP="$RIDE_RELAY_BUILD_TIMESTAMP" \
  --dart-define=RIDE_RELAY_API_BASE_URL=https://relay.tailendcharlie.app/api
```

A local `flutter build appbundle --release` succeeds and is signed with the
**debug** key, silently — it is not a release artefact and cannot be uploaded to
Play. Only `android-internal.yml` produces one.

### Reproduce what CI checks

```bash
cd apps/mobile
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
```

```bash
cd apps/server
uv sync --frozen --extra dev
uv run ruff format --check .
uv run ruff check .
uv run pytest
```

The unsigned iOS build CI performs, which needs no Apple signing identity:

```bash
cd apps/mobile
flutter build ios --debug --no-codesign
```

### Store channels

Both are manual `workflow_dispatch` runs; neither fires on a push or a pull
request. They need repository secrets and store credentials that are not in the
repository.

```bash
gh workflow run "TestFlight" --ref <branch>
gh workflow run "Android internal testing" --ref <branch> \
  --field promote_to=alpha --field notification_mode=auto
```

Both require the `RIDE_RELAY_API_BASE_URL` repository variable and fail with a
clear message without it. See
[android-internal-testing.md](./android-internal-testing.md) and
[release-signing.md](./release-signing.md).

## Symptom index

You arrive here with a symptom. Find it, then read the cause.

| Symptom | Section |
| --- | --- |
| App crashes immediately on launch; console mentions `FlutterEngine` and debug mode | [Crashes immediately when launched from the home screen](#crashes-immediately-when-launched-from-the-home-screen) |
| App crashes immediately on launch, no Flutter message, right after a signing change | [Crashes immediately after the CarPlay entitlement was removed](#crashes-immediately-after-the-carplay-entitlement-was-removed) |
| A `--release` build builds but will not install on the phone; the install is rejected over the provisioning profile or its device list | [A release build will not install on a device](#a-release-build-will-not-install-on-a-device) |
| "No profiles for 'app.tailendcharlie' were found" / signing looks broken locally | [No provisioning profile found, or none installed](#no-provisioning-profile-found-or-none-installed) |
| "No development certificate for team `UY4624PH6X`" although `security find-identity` lists one | [The certificate exists but appears to be for another team](#the-certificate-exists-but-appears-to-be-for-another-team) |
| Xcode cannot create a profile / automatic signing fails on the CarPlay entitlement | [Automatic signing cannot work for this app](#automatic-signing-cannot-work-for-this-app) |
| Xcode has no "Connect via network" checkbox for the phone | [The phone will not pair wirelessly](#the-phone-will-not-pair-wirelessly) |
| Install finishes, then Xcode or Flutter hangs on "taking longer than expected" | [The debugger will not attach over Wi-Fi](#the-debugger-will-not-attach-over-wi-fi) |
| **About & build** says `unknown` | [What a device build must have stamped in](#what-a-device-build-must-have-stamped-in) |
| Relay host blank on **About & build**; no server traffic | [What a device build must have stamped in](#what-a-device-build-must-have-stamped-in) |

### Crashes immediately when launched from the home screen

The device console says something like `Cannot create a FlutterEngine instance
in debug mode without Flutter tooling or Xcode`, and the crash report shows
`signal 11` (`SIGSEGV`).

You built and installed a **debug** build, then launched it by tapping the icon.
iOS 14 and later forbid the just-in-time compilation that Flutter's debug mode
depends on unless a debugger is attached. The app is fine; the configuration is
wrong for the purpose.

Use `--profile` — see
[A physical iPhone](#a-physical-iphone--the-device-evaluation-path). A debug
build is only usable while `flutter run` or Xcode stays attached.

This one looks exactly like an application crash. It is not. Before reporting a
launch crash on a device build, confirm which configuration produced the
binary.

### A release build will not install on a device

The Runner target's Release configuration is pinned to
`PROVISIONING_PROFILE_SPECIFIER =
"Tail End Charlie CarPlay Navigation App Store"`. An App Store profile has no
`ProvisionedDevices` array — confirmed on the locally installed copy of that
profile — so iOS has no basis on which to install the resulting binary on a
development device.

This is a consequence of the CI setup being correct, not a defect. **Profile**
is the device configuration: it already uses the CarPlay Development profile and
the development entitlements. For a genuinely release-identical build on a
phone, go through TestFlight.

### No provisioning profile found, or none installed

Two directories exist and both are real:

- `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` — Xcode 16 and
  later manage this one, and it is where Xcode puts profiles it downloads
  itself.
- `~/Library/MobileDevice/Provisioning Profiles/` — the legacy path. Still read
  by the toolchain, still where a manually downloaded profile usually lands, and
  the path `testflight.yml` installs the CI profile into before a successful
  archive.

Checking only one of them is what produced a confident, wrong conclusion that
local signing was broken during the 26 July session. On the maintainer's Mac
that same day the Xcode 16+ directory held six profiles and the legacy
directory held exactly one — and the one in the legacy directory was
the predecessor `Tail End Charlie CarPlay Development` profile. The current
Debug and Profile configurations name
`Tail End Charlie CarPlay Navigation Development`. Neither directory is
authoritative. Search both:

```bash
# -a matters: without it, BSD grep -r finds nothing in these binary files.
grep -rla "Tail End Charlie CarPlay Navigation Development" \
  ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/ \
  ~/Library/MobileDevice/Provisioning\ Profiles/ 2>/dev/null
```

To read a profile's name, expiry and entitlements:

```bash
security cms -D -i <profile>.mobileprovision | plutil -p - | less
```

Creating or downloading the profile itself needs the maintainer's Apple
account. See [Account-bound actions](#account-bound-actions).

### The certificate exists but appears to be for another team

`security find-identity` prints the certificate's **common name**, and for an
Apple Development certificate the value in brackets is the **Apple ID's**
identifier, not the team. The team is the `OU` field of the subject.

```bash
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
```

produces a subject of the form

```
subject=UID=<apple-id-uid>, CN=Apple Development: someone@example.com (<APPLE-ID-IDENTIFIER>), OU=UY4624PH6X, O=<name>, C=US
```

`OU=UY4624PH6X` is the team, and it matches `DEVELOPMENT_TEAM` in
`project.pbxproj` and `teamID` in `ios/ExportOptions-TestFlight.plist`. Reading
the bracketed value in the common name as the team is what led to a wrong
conclusion that no development certificate existed for the team.

An `Apple Distribution` certificate is not the same shape: its common name
brackets *do* carry the team ID. Do not generalise from one to the other — read
the `OU`.

### Automatic signing cannot work for this app

`com.apple.developer.carplay-driving-task` and
`com.apple.developer.carplay-maps` are restricted entitlements. Xcode cannot
mint a profile that carries them, so `CODE_SIGN_STYLE = Automatic` cannot
satisfy this target. All three Runner configurations are deliberately
`Manual`. Switching any of them to automatic will fail, and the failure will
point at an entitlement.

Do not resolve that failure by removing the entitlement — see the next section.
See also
[release-signing.md](./release-signing.md#certificates-profiles-and-the-carplay-pair).

### Crashes immediately after the CarPlay entitlement was removed

`apps/mobile/ios/Runner/Info.plist` declares a
`CPTemplateApplicationSceneSessionRoleApplication` scene whose delegate is
`CarPlaySceneDelegate`. iOS terminates an app that declares a scene role it is
not entitled to. The two CarPlay entitlements in
`Runner/DebugProfile.entitlements`/`Runner/Release.entitlements`, the App ID
capabilities, the provisioning profile and that scene declaration must agree;
removing one part alone can kill the app at launch.

Restore whichever you removed. If CarPlay ever genuinely has to come out, both
sides go together, and that is a product decision recorded against issue #6,
not a signing workaround.

### The phone will not pair wirelessly

Xcode's **Connect via network** checkbox only appears after the device has been
paired over USB at least once. There is no wireless-only route to a first
pairing.

Diagnosing whether a cable is carrying data is genuinely fiddly, and the
obvious check is not the reliable one. Observed on the maintainer's Mac on
26 July 2026: `flutter devices --device-connection attached` listed an iPhone
while `system_profiler SPUSBDataType` and `system_profiler
SPThunderboltDataType` both reported nothing on the bus. Flutter's "attached"
label can include a network-paired device, so it does not answer the cable
question.

```bash
xcrun devicectl list devices        # state and hostname per paired device
system_profiler SPUSBDataType      # what is actually on the USB bus
```

If `system_profiler SPUSBDataType` does not list the phone, there is no USB data
path: a charge-only cable, a bad port, or a device that has not booted. That is
not a missing trust prompt, and re-plugging to hunt for a "Trust this computer"
dialog will not produce one.

### The debugger will not attach over Wi-Fi

The install completes and then Xcode or Flutter sits on "taking longer than
expected" while attaching. The install has already happened at that point —
check the phone's home screen before assuming the whole operation failed. A
cable fixes the attach. `flutter run --device-connection attached` restricts
discovery to attached devices, so the tooling cannot pick the wireless one when
both are paired.

## The state of signing

**Both CI signing paths work, are evidenced, and must not be "fixed".**

**iOS — `.github/workflows/testflight.yml`.** Decodes an
`Apple Distribution` `.p12` and the
`Tail End Charlie CarPlay Navigation App Store` provisioning profile from
repository secrets into `$RUNNER_TEMP`, creates a temporary keychain, imports
the certificate with `-T /usr/bin/codesign`, installs the profile by its UUID,
archives the **Release** configuration with `xcodebuild`, exports it manually
per `ios/ExportOptions-TestFlight.plist`
(`signingStyle: manual`, `signingCertificate: Apple Distribution`,
`teamID: UY4624PH6X`), and uploads with `xcrun altool`. Evidence: TestFlight
workflow runs **20** and **23–26** completed successfully (24 July 2026), each
including the upload step with the predecessor profile. The replacement
profile secret was installed on 29 July; a signed workflow run remains the
release-signing evidence needed for navigation.

**Android — `.github/workflows/android-internal.yml`.** Writes
`android/key.properties` from the upload-keystore secrets in `$RUNNER_TEMP`,
builds a **Release** App Bundle, uploads it to Play's `internal` track with a
least-privilege Play service account, and promotes it to the closed `alpha`
track in the same run. Evidence: `Android internal testing` runs **6–8** and
**10–15** completed successfully, the later ones including promotion.

What that means in practice: a local signing problem is a local problem. Changes
to `project.pbxproj`, `ExportOptions-TestFlight.plist`, the entitlements files,
or the workflows' signing steps are release decisions — raise them rather than
making them to unblock a local build.

Neither pipeline can observe the store. What still needs Play Console access, an
App Store Connect session, or a physical phone is listed in
[android-internal-testing.md § What cannot be verified from CI](./android-internal-testing.md#what-cannot-be-verified-from-ci).

## Account-bound actions

These require the maintainer's authenticated Apple account or remain
intentionally manual.

- **Changing an App ID or issuing a provisioning profile.** A Developer-scoped
  App Store Connect API key returned `403` on `POST /v1/devices` and
  `POST /v1/profiles` during the 26 July session. The signed-in Developer portal
  did work on 29 July after explicit maintainer confirmation: it enabled
  CarPlay Navigation and created both replacement profiles. Do not treat an API
  permission failure as proof that the portal action is impossible.
- **Editing a provisioning profile through the API.** Reported from that
  session: profiles can be created and deleted but not modified. If you must
  work with profiles, probe your permissions by creating one with a throwaway
  name **first**, and only delete a real profile once you know you can recreate
  it. Deleting `Tail End Charlie CarPlay Navigation Development` or
  `Tail End Charlie CarPlay Navigation App Store` without being able to
  recreate it breaks device builds and TestFlight respectively.
- **The first USB pairing.** Wireless debugging is only offered afterwards.
- **Erasing or resetting a device.** The maintainer's decision alone. Never do
  this, and never advise it as a debugging step for a build problem.
- **Registering a device UDID.** Needs the maintainer's account, and the UDID
  itself must never be committed — not in a doc, a script, a workflow, or a
  commit message.

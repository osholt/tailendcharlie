# Build and signing policy

This document is the signing policy. For *which configuration to build for which
purpose*, the `--dart-define` values a device build needs, the exact commands,
and a symptom-first index of the ways a local device build goes wrong, read
[build-and-run.md](./build-and-run.md) first.

## Development phase

- Android CI produces a debug APK signed only with the runner's standard,
  ephemeral Android debug certificate.
- iOS CI uses `flutter build ios --debug --no-codesign` and uploads the unsigned
  `.app` directory as a build artifact.
- There are no release keystores, Apple certificates, provisioning profiles, or
  signing secrets stored in the repository. The manual TestFlight workflow only
  reads signing material from GitHub Actions secrets once those are configured.

Unsigned iOS applications cannot normally be installed on a physical iPhone.
The Runner target's Debug and Profile configurations use the locally installed
`Tail End Charlie CarPlay Navigation Development` profile. Manual signing is
required because automatic signing does not select a manually issued profile
carrying the restricted CarPlay entitlements. The profile must include the
developer's Apple Development certificate and test device; it is never stored
in the repository.

A Debug build is signed and installable but **cannot be launched from the home
screen** - iOS 14 and later forbid the JIT that Flutter's debug mode needs
without an attached debugger. Use the Profile configuration for anything a
person is meant to tap. `--release` is not the device configuration here either:
it is pinned to the App Store profile, which contains no provisioned devices.
[build-and-run.md](./build-and-run.md) covers both.

## Certificates, profiles, and the CarPlay pair

Three facts that cost hours during the local-device evaluation on 26 July 2026,
each of them the sort of thing that produces a confident wrong answer.

**Provisioning profiles live in two places, and both are real.** Xcode 16 and
later manage
`~/Library/Developer/Xcode/UserData/Provisioning Profiles/`; the legacy
`~/Library/MobileDevice/Provisioning Profiles/` is still read by the toolchain
and is still where a manually downloaded profile usually lands - it is also the
path the `TestFlight` workflow installs the CI profile into before a successful
archive. Neither directory is authoritative, and either can be empty or
incomplete on a machine whose signing works perfectly. On the maintainer's Mac
on 26 July the Xcode 16+ directory held six profiles and the legacy directory
held exactly one: the then-current `Tail End Charlie CarPlay Development`
profile. The navigation replacement now named by Debug and Profile builds is
`Tail End Charlie CarPlay Navigation Development`. Checking only one path is
what produced a wrong conclusion that local signing was broken. Search both:

```bash
# -a matters: without it, BSD grep -r finds nothing in these binary files.
grep -rla "Tail End Charlie CarPlay Navigation Development" \
  ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/ \
  ~/Library/MobileDevice/Provisioning\ Profiles/ 2>/dev/null
```

**A team ID inside a certificate's name is not the team.**
`security find-identity` prints the certificate's common name, and for an Apple
Development certificate the bracketed value there is the **Apple ID's**
identifier. The team is the `OU` field of the subject:

```bash
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
```

```
subject=UID=<apple-id-uid>, CN=Apple Development: someone@example.com (<APPLE-ID-IDENTIFIER>), OU=UY4624PH6X, O=<name>, C=US
```

`OU=UY4624PH6X` is the team, matching `DEVELOPMENT_TEAM` in `project.pbxproj` and
`teamID` in `ios/ExportOptions-TestFlight.plist`. Reading the common name's
brackets as the team led to a wrong conclusion that no development certificate
existed for this team. An `Apple Distribution` certificate does put the team ID
in its common name, so do not generalise from one to the other - read the `OU`.

**The CarPlay entitlements and scene declaration are one signing unit.**
`com.apple.developer.carplay-driving-task` and
`com.apple.developer.carplay-maps` in the Debug/Profile and Release entitlement
files, the matching capabilities on `app.tailendcharlie`, and the
`CPTemplateApplicationSceneSessionRoleApplication` scene in `Runner/Info.plist`
must agree. The navigation scene uses the window-bearing delegate callback and
a `CPMapTemplate` root, so a profile without `carplay-maps` is not a usable
substitute. iOS terminates an app at launch if it declares a scene role it is
not entitled to. Automatic signing cannot mint these restricted profiles;
all Runner configurations therefore remain manual.

Apple approved CarPlay Navigation under Case-ID 21286533. On 29 July 2026 the
capability was enabled on App ID `app.tailendcharlie`, invalidating the previous
profiles. The replacements are:

- `Tail End Charlie CarPlay Navigation Development`, UUID
  `2f1ad93d-9320-4046-a54e-908dc2639d44`, with two development certificates and
  two test devices.
- `Tail End Charlie CarPlay Navigation App Store`, UUID
  `e87d428b-76d2-4aa5-b455-45e0bd3339d4`, using the same distribution
  certificate as the previously working CI profile.

Both embed Associated Domains, Push Notifications, CarPlay Driving Task and
CarPlay Navigation. The development profile has `aps-environment =
development`; the App Store profile has `aps-environment = production`. The
old profiles remain in the portal as invalid historical records.

## CI signing is already correct - do not change it

Both CI signing paths work and are evidenced. A local signing problem is a local
problem; it is not a reason to edit `project.pbxproj`,
`ios/ExportOptions-TestFlight.plist`, the entitlements files, or a workflow's
signing steps.

- **iOS**: `testflight.yml` imports an `Apple Distribution` `.p12` and the
  `Tail End Charlie CarPlay Navigation App Store` provisioning profile into a
  temporary keychain and signs manually per
  `ios/ExportOptions-TestFlight.plist`. Runs **20** and **23-26** proved the
  signing path with the predecessor profile. The replacement profile secret
  was installed on 29 July; a signed workflow run is still required as
  evidence for the navigation profile.
- **Android**: `android-internal.yml` signs with the upload keystore and
  publishes through a least-privilege Play service account.
  `Android internal testing` runs **6-8** and **10-15** completed successfully,
  the later ones including promotion to the closed `alpha` track.

Changes here are release decisions. Raise them rather than making them to
unblock a local build.

## TestFlight beta distribution

The iOS target uses bundle ID `app.tailendcharlie`. The Runner target's Release
configuration is signed manually (`CODE_SIGN_STYLE = Manual` in
`project.pbxproj`) with a `PROVISIONING_PROFILE_SPECIFIER` naming an exact
profile - CI has no Apple ID signed into Xcode to resolve a profile
automatically. That profile name must match in three places: the CI-created
provisioning profile itself, the
`PROVISIONING_PROFILE_SPECIFIER` build setting, and the `provisioningProfiles`
entry in `ios/ExportOptions-TestFlight.plist`. `ExportOptions-TestFlight.plist`
only governs the later `-exportArchive` step, not the archive step itself -
mismatching just that file while missing `PROVISIONING_PROFILE_SPECIFIER`
still fails the build with "No profile ... found" during archiving. The
`TestFlight` GitHub workflow is manual only, so normal commits and pull
requests never send a build to Apple.

Changing capabilities on `app.tailendcharlie` invalidates every profile for
that App ID. The two replacements above were generated and checked for both
`com.apple.developer.carplay-driving-task` and
`com.apple.developer.carplay-maps`; `APPLE_APPSTORE_PROFILE_BASE64` was replaced
with the new App Store profile on 29 July 2026.

The app previously shipped internal TestFlight builds under bundle ID
`me.osholt.rideRelay`. That identifier is retired - Apple never allows a bundle
ID to be changed on an existing App Store Connect app record, so matching the
Android `app.tailendcharlie` rename meant registering a new App ID and starting
a new app record rather than editing the old one. Existing internal testers
need re-adding under the new record; TestFlight build history does not carry
over.

Before the first upload under the new identifier, register the `app.tailendcharlie`
App ID in the Apple Developer portal; sign in to App Store Connect as an Account
Holder, Admin, App Manager, or Developer; create the `Tail End Charlie` iOS app
record using that bundle ID; and accept any outstanding agreements. Create a
least-privilege App Store Connect API key and an App Store provisioning
profile - name it to match both `PROVISIONING_PROFILE_SPECIFIER` in
`project.pbxproj` and the `provisioningProfiles` entry in
`ios/ExportOptions-TestFlight.plist` - then add these repository secrets:

- `APPLE_DISTRIBUTION_CERTIFICATE_BASE64` and
  `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD` — an Apple Distribution `.p12`.
- `APPLE_APPSTORE_PROFILE_BASE64` — the App Store provisioning profile.
- `APPLE_CI_KEYCHAIN_PASSWORD` — a random, dedicated temporary-keychain
  password.
- `APPSTORE_CONNECT_API_KEY_ID`, `APPSTORE_CONNECT_API_ISSUER_ID`, and
  `APPSTORE_CONNECT_API_PRIVATE_KEY_BASE64` — the Developer-role App Store
  Connect API key used only to upload the IPA.
- `APPSTORE_CONNECT_REVIEW_API_KEY_ID`,
  `APPSTORE_CONNECT_REVIEW_API_ISSUER_ID`, and
  `APPSTORE_CONNECT_REVIEW_API_PRIVATE_KEY_BASE64` — a separate App
  Manager-role key used only to assign the processed build to the external
  tester group and create the beta review submission.

Keep the two App Store Connect keys separate. The Developer key is deliberately
least-privilege for routine uploads. Apple requires App Manager or higher to
create a beta review submission, and a Team key applies to every app in the
account, so the broader review key must not replace the upload key. Store its
one-time-download private key outside the repository at
`~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`, mode `600`, with an
encrypted recovery copy.

Set `RIDE_RELAY_IOS_EXTERNAL_TESTER_GROUP` to the exact App Store Connect group
name (currently `External Testers`). The manual workflow's
`submit_external` input defaults to true. After upload, it waits for processing,
assigns the build to that group, and creates an idempotent beta review
submission. Set the input to false only when deliberately uploading an
internal-only build.

Run **TestFlight** from the Actions tab and provide a unique build number if the
default GitHub run number has already been uploaded. Apple processes the upload
before it appears under the app's TestFlight tab. External TestFlight testing
still requires Apple's beta review, privacy, age-rating, export-compliance and
test-information metadata, but the workflow now submits the eligible build
without a manual App Store Connect click.

## Before public App Store distribution

Create a separate release checklist covering bundle IDs, Apple Developer and
Google Play ownership, protected GitHub environments, short-lived CI secrets,
key rotation/recovery, notarised artifact provenance, and staged rollout. Never
reuse debug keys for release builds.

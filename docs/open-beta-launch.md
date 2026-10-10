# Open beta launch

Prepared 10 October 2026 for #861. The plan, gates and phases are in
[open-beta-plan.md](./open-beta-plan.md); this is what happens on the day, and
the store answers that have to be given first.

**Nothing in this repository has touched a store.** No workflow has been
dispatched against Google Play or App Store Connect, no track has been promoted
and no public link has been changed. Everything below that changes store state
is a step for the operator, or for Claude on the operator's explicit go, one
dispatch at a time.

## Decisions this is built on

Recorded on #861 on 9 and 10 October 2026:

1. Routing and geocoding are self-hosted on an Oracle Always Free ARM VM
   ([routing-service.md](./routing-service.md), #917).
2. Phase 1 cap: **100** testers (TestFlight public link and Play open testing,
   United Kingdom only).
3. Support address: **testing@tailendcharlie.app** (forwards to the operator).
4. Minimum age: **17**.
5. The Play open-testing build ships **without Android Auto**.

## What exists in the repository

| Piece | Where | Notes |
| --- | --- | --- |
| Open-testing release gate | `Android internal testing` and `Promote Android testing release` inputs `confirm_open_testing`; `tools/release/play_release_gate.py` | `promote_to=beta` fails unless the phrase `publish-open-testing` is typed, refuses an Android Auto bundle, sends no closed-group mail, and reads `beta` back afterwards. See [android-internal-testing.md](./android-internal-testing.md#open-testing-beta-the-public-track). |
| Android Auto switch | `-PandroidAuto=true` in `apps/mobile/android/app/build.gradle.kts`; `android_auto` workflow input | **Off in every build today.** Android Auto has been absent from every Play bundle, `alpha` included, since build 88 (5 September). No track carries it. |
| TestFlight public link | `TestFlight public link` workflow; `tools/testflight/beta_distribution.py` | `verify` (read-only), `test-info`, `public-link-enable`, `public-link-disable`. Dry run until `apply`; enabling also needs `enable-public-link`. See [release-signing.md](./release-signing.md#public-link-for-the-open-beta). |
| Listing text | `docs/open-beta-listing/` | TestFlight beta description, review notes, What to Test; Play short and full descriptions and release notes. Guarded by `tools/testflight/test_beta_listing.py`. |
| Beta support in the app | Settings > About: **Beta support**; About & build: **Email beta support** | Opens a message to the support address with the build identity in the body and nothing else. |
| Beta support on the website | Home page, footer; privacy policy and terms | Support is `testing@`; data requests stay with `privacy@`. |
| Age 17 | `privacy.html`, `terms.html` | Both said 16 before. |

## Store answers

These are drafted from the actual data flows and from
[the privacy policy](../apps/website/privacy.html). They are answers to give,
not forms filed. Where a store's wording or options may have changed, the Console
is authoritative: read the question and check the answer still fits.

### Apple: age rating

TestFlight external testing needs no age rating. It is required when the app is
submitted to the App Store (phase 3).

Questionnaire answers: no violence, sexual content, nudity, profanity or crude
humour, horror, drugs, alcohol or tobacco references, gambling, contests or
medical content. No web browsing inside the app (links open in the system
browser). No advertising. No messaging or chat between users: riders exchange
position, hazard reports and a fixed set of preset messages. A rider chooses a
display name that other riders in the same ride can see; that is the only
user-entered text shared. Location is shared with other users of the same ride.

Expected result: the lowest rating the questionnaire gives. **Decision for the
operator:** the minimum age is 17 because of motorcycle licensing, and the
current Apple scale (4+, 9+, 13+, 16+, 18+) has no 17+ tier. The honest options are
to accept the calculated rating and enforce 17 through the terms, the privacy
policy and the listing (what is in place), or to override to **18+**, which
excludes 17-year-old riders. Check the options in App Store Connect before
choosing. The 17+ statement is already in the TestFlight description, review
notes, terms and privacy policy.

### Google Play: content rating and audience

- **Content rating (IARC questionnaire):** category is a utility or
  navigation-style app, not a game or social network. Answer no to violence,
  sexuality, profanity, controlled substances, gambling, digital purchases and
  unrestricted web access. Answer **yes** to "users can interact or exchange
  content" (riders in one ride exchange position, hazard reports and preset
  messages; no free-text chat) and **yes** to "shares the user's location with
  other users". Those are labels, not rating raisers. Expect the lowest rating.
- **Target audience:** declare the age groups the 17+ terms allow. Play's bands
  are 16 to 17 and 18 and over. Selecting only 18 and over would contradict the
  17+ terms and exclude 17-year-olds; **recommended: 16 to 17 and 18 and over**,
  accepting the teen-audience questions (the app is not child-directed, has no
  ads and no accounts). Do not select any band under 16.
- **Ads:** no. **App access:** all functionality is available without an account
  or special access. **Government, financial, health, news, COVID apps:** no.
- **Advertising ID:** the app does not use it; the merged release manifest has
  no `AD_ID` permission (checked in a release build on 10 October).
- **Foreground service declaration (`FOREGROUND_SERVICE_LOCATION`):** the app
  keeps a ride recording and shares position while the phone is in a pocket or
  showing another navigation app, which needs a location foreground service
  (#205). It runs only during an active ride, shows a notification, and stops
  when the ride ends, sharing is paused, or a rider who has been away from the
  group does not answer the prompt (`background-location.md`). The app
  deliberately does **not** request `ACCESS_BACKGROUND_LOCATION`, so the
  background-location declaration is not needed. If the Console asks for it
  anyway, stop and ask.
- **Permission rationales:** location (ride sharing and navigation), notifications
  (ride alerts), camera (scanning an invitation, optional), nearby devices and
  Bluetooth (the experimental phone-to-phone path, optional). In-app wording is
  in `AndroidManifest.xml` comments and the iOS usage descriptions.
- **Privacy policy URL:** `https://tailendcharlie.app/privacy.html`.
- **Data deletion:** there are no accounts, so Play's account-deletion
  requirement does not apply. Relay data deletes itself on a schedule, and
  earlier deletion is requested at `privacy@tailendcharlie.app`; the policy's
  "Deleting your information" section describes both.

### Google Play: Data safety

All data is encrypted in transit (TLS). There is no advertising, analytics or
crash-reporting SDK. Deletion: users can request it by email; most data deletes
itself (positions after 30 minutes, ride records within 72 hours).

Collected means it leaves the phone, to us or to a provider. Over-declaring is the
safe direction; under-declaring risks a policy strike.

| Play data type | Collected | Shared | Required or optional | Purpose | What it is |
| --- | --- | --- | --- | --- | --- |
| Location: precise | Yes | Yes | Optional (needed only to share with a group) | App functionality | Live position to the relay and to the other riders in the ride; route points to routing and speed-limit services. |
| Location: approximate | Yes | Yes | Optional (can be turned off) | App functionality | Heatmap coverage cells (about 170 to 210 m), sent under a separate random credential and published only as a thresholded public aggregate. **Contribution is opt-in and asked at setup** (#957, operator decision of 10 October 2026): first-run setup offers always / ask after each ride / never with nothing pre-selected, skipping means never, and an install that never stored a choice is asked once on the home map and shares nothing until it answers. Confirm the build you ship still does this. |
| Personal info: name | Yes | Yes | Required to join a ride | App functionality | The display name a rider chooses, shown to the group. It need not be a real name. |
| Personal info: phone number | Yes | Yes | Optional | App functionality | Emergency-contact number, only if the rider shares it with the group or leader (it stays on the phone otherwise); relay copy kept 2 hours. |
| Health and fitness: health info | Yes | Yes | Optional | App functionality | Medical notes on the emergency contact, same conditions as above. |
| App activity: in-app search history | Yes | Yes | Optional | App functionality | A destination search is sent to the geocoder. Not stored by the relay. |
| App activity: other user-generated content | Yes | Yes | Optional | App functionality | Hazard, police and speed-camera reports and preset alerts, shared with the group. |
| Messages: other in-app messages | Yes | Yes | Optional | App functionality | Preset quick messages and leader broadcasts. There is no free-text chat. |
| Device or other IDs | Yes | Yes | Required (ride) / optional (push) | App functionality | A random installation identifier in ride events; the FCM registration token if notifications are allowed, encrypted on the relay per ride and removed on leaving. Shared with Google (FCM). |

Not collected: contacts, photos, files, audio, calendar, financial info, web
browsing, crash logs and diagnostics. Opt-in ride diagnostics are written on the
phone and leave only if the rider shares them. The camera is used to scan a code
and nothing is stored or sent.

**"Shared" depends on routing.** Until the self-hosted routing service is cut
over (#917, #927, #929), route points, speed-limit lookups and search text go to
public third-party services (FOSSGIS Valhalla, OpenStreetMap Nominatim, Project
OSRM), so declare them shared. After cut-over they go to a service we run, which
Play treats as a service provider rather than sharing, **but only once
`privacy.html` and the terms say so**; both still describe the public services
(see the launch gate below). Rider-to-rider sharing is user-initiated and is
declared anyway.

### Apple: App Privacy (for App Store submission)

Not needed for TestFlight. Prepare it from the same inventory when phase 3 is
decided: **no tracking**; data linked to the user (a persistent random device
identifier makes it linked): precise location, coarse location, name, phone
number, health, search history, other user content, device ID; all for **App
Functionality** only. An app-level `PrivacyInfo.xcprivacy` does not exist in the
Runner target and App Store submission will need one.

### Support

`testing@tailendcharlie.app`, in the TestFlight feedback email, the Play listing
contact, the website and the app. Send it a message before launch and confirm it
reaches the operator. Replies come from the same address.

## Launch checklist

Each step has its verification. Do not start a step until the one before it has
passed. **Who:** *Operator* does it in a console or settings page; *Claude* runs a
workflow or checks, only on the operator's go for that step; *Either*.

### A. Gate checks (days before)

| # | Step | Who | Verify |
| --- | --- | --- | --- |
| A1 | Read the status table in [open-beta-plan.md](./open-beta-plan.md#launch-status-10-october-2026) and agree each open item is accepted, deferred or blocking. | Operator | Decision written on #861. |
| A2 | Build 103 is merged to `main` with every protected check green. | Claude | `gh pr checks`; main head recorded on #861. |
| A3 | Relay deployed at the merged commit; `serverBuildCommit` matches. If no server code changed, dispatch `relay-deploy.yml` by hand. | Claude | `curl -s https://relay.tailendcharlie.app/api/v1/compatibility \| jq -r .serverBuildCommit` equals the main head. `relay-health.yml` green. |
| A4 | Routing and geocoding service cut over and smoke-tested ([routing-service.md](./routing-service.md)); `privacy.html`, `terms.html` and the Data safety "shared" answers updated to match what is live. | Operator + Claude | Routing smoke script output on #861; the policy no longer says riders' routes go to the public services, or the Data safety form still says shared. |
| A5 | Support inbox works. | Operator | A test mail to `testing@tailendcharlie.app` arrives. |
| A6 | Pick the build number: higher than every code on Play and every build in App Store Connect, and use the same number on both. | Claude | `gh workflow run "Play track status"`; the dispatch's first step also checks it (#630). |
| A7 | The tester notes for the build are in [tester-release-notes.md](./tester-release-notes.md) and say what open testers will see. | Claude | File on `main`. |

### B. Console preparation (before the build, nothing public yet)

| # | Step | Who | Verify |
| --- | --- | --- | --- |
| B1 | Play Console > App content: give the answers above (privacy policy URL, ads, app access, content rating, **target audience**, **Data safety**, foreground service declaration). | Operator | Every item shows complete; the Publishing overview shows no required action. |
| B2 | Play Console > Advanced settings > Form factors: **Android Auto is not added.** The opt-in is per app, not per track. If it shows as added, stop and tell Claude. | Operator | Screenshot or the text of the setting posted on #861. |
| B3 | Play Console > Open testing: **countries = United Kingdom only**; feedback contact email `testing@tailendcharlie.app`; short tester-facing description if asked. | Operator | The open-testing settings page shows UK only and the contact. |
| B4 | Play Console > Open testing: the track is **paused**. Managed publishing is **off**. Production access is available. | Operator | State read in the Console (the API cannot see a pause). |
| B5 | Play Console > Store listing for the app: fill the short and full descriptions from `docs/open-beta-listing/play-short-description.txt` and `play-full-description.txt`, and the release notes from `play-release-notes.txt`. | Operator | Listing preview matches the files. |
| B6 | App Store Connect > TestFlight > Test Information and Beta App Review contact are filled. Run the workflow: `TestFlight public link`, `action=test-info`, **apply off** first. | Claude | Dry-run line says what would change; then repeat with `apply` ticked and the run reads it back. Then `action=verify` shows `test-info` ok. |
| B7 | In Test Information, **Beta App Review notes** are filled from `docs/open-beta-listing/testflight-review-notes.txt`; contact name, phone and email are the operator's. | Operator | `verify` shows `review-contact` ok (it names what is missing and never prints the values). |

### C. Builds (one to two days before, for review time)

| # | Step | Who | Verify |
| --- | --- | --- | --- |
| C1 | iOS: `gh workflow run TestFlight --ref main --field build_number=<N> --field submit_external=true`. | Claude | Run green; `TestFlight status` for `<N>` reports the beta review state. |
| C2 | Wait for Beta App Review to approve build `<N>` (may take a day or more). | Operator | `gh workflow run "TestFlight status" --field build_number=<N>` prints `APPROVED`; `TestFlight public link` `verify` shows `builds` ok. |
| C3 | Android: `gh workflow run "Android internal testing" --ref main --field build_number=<N> --field promote_to=beta --field confirm_open_testing=publish-open-testing --field android_auto=false --field notification_mode=dry-run`. The track is paused, so this serves nobody. | Claude | Run green. The summary says Android Auto declarations `false` and that beta holds the build; the steps "Verify the Android Auto declarations match the build" and "Read the open-testing track back" passed. |
| C4 | Closed testers need the same bundle: `gh workflow run "Promote Android testing release" --field version_code=<N> --field source_track=beta --field target_track=alpha`. (They will see "Play open testing (beta)" on About & build, because the track is stamped at build time. Build a separate number for `alpha` if that matters.) | Claude | Run green. |
| C5 | `gh workflow run "Play track status"`. | Claude | `beta` and `alpha` list `<N>` with status `completed`. |
| C6 | Play Console > Publishing overview: the release is not stuck "in review" or queued for publishing. If Google is reviewing it, wait. | Operator | No pending changes. |
| C7 | Install the build from `internal` or `alpha` on a real phone and check **Settings > About & build** (version, build `<N>`, track) and that the app reaches the relay. | Operator | About & build shows the expected values; relay access log shows `x-tailendcharlie-app-build: <N>`. |

### D. Open the doors (launch day)

| # | Step | Who | Verify |
| --- | --- | --- | --- |
| D1 | Re-run every A check that can drift: `serverBuildCommit`, `relay-health.yml`, routing smoke. Confirm the support inbox is being watched. | Claude | All green; operator says "go". |
| D2 | **Android:** Play Console > Open testing > **Resume track** (unpause). | Operator | Console shows the track active. |
| D3 | Open `https://play.google.com/apps/testing/app.tailendcharlie` **from an account that is not on any tester list**, on a real Android phone, with no invitation. | Operator | The page offers **Become a tester**, then a download link; install it; About & build says build `<N>` and `Play open testing (beta)`; the relay access log shows `x-tailendcharlie-distribution-track: beta`. If the page says the app is not available, the track is still paused or in review. |
| D4 | **iOS:** read the current link. `TestFlight public link`, `action=verify`, `expect_link=any`. A link (`testflight.apple.com/join/...`) may already exist from the closed beta. | Claude | Report shows link state, address, cap and tester count. Record the address on #861. |
| D5 | Dry run: `action=public-link-enable`, `link_limit=100`, apply off. | Claude | "Dry run: would set ..." and no error about missing builds. |
| D6 | Enable: same, **apply on**, `confirm_public_link=enable-public-link`. | Claude, on go | "Public link enabled ... and read back." |
| D7 | `action=verify`, `expect_link=enabled`, `link_limit=100`. | Claude | Every check `ok`: link enabled, cap 100 enforced, an installable build, test information, review contact. |
| D8 | Set the repository variable `RIDE_RELAY_TESTFLIGHT_INVITE_URL` to the address from D4, so the next iOS build's update button opens it. | Operator | Settings > Secrets and variables > Actions shows it. |
| D9 | Open the link on an iPhone with no invitation. | Operator | TestFlight offers the app; install; About & build shows build `<N>`, `TestFlight`. |
| D10 | Post the two links: the Play opt-in page and the TestFlight link, with the support address, to the first groups (Bike and Brew, existing testers' clubs). Update `docs/tester-update-guide.md`, the website home page and the printed join sheet in one follow-up PR if the address changed. | Operator | Posted; the PR is open. |
| D11 | Comment on #861 with the build number, both links, the run URLs and the time. | Claude | Comment exists. |

### E. Monitoring

| When | What | Who | Act if |
| --- | --- | --- | --- |
| First hour | `relay-health.yml` runs every 5 minutes and opens an alert issue on failure. Watch the relay (`docs/server-runbook.md`, Operations): errors, sync latency, memory. Watch the support inbox. | Operator + Claude | Any relay alert, sustained errors, or a privacy-sensitive report: **roll back**. |
| First day | TestFlight crash reports in App Store Connect; Android vitals in Play Console (crash and ANR rates); `TestFlight public link` `verify` for the tester count against 100; `Play track status`. | Operator | Crash-free sessions below 99%, a crash cluster on one screen, or the cap reached. |
| First week | New feedback becomes a GitHub issue within 48 hours, with the existing labels; a short release note goes into `tester-release-notes.md`; compare crash-free sessions with the 99.5% gate. | Claude | Same. |
| Weekly | At most one tester build a week, relay deployed at the same commit, build numbers strictly increasing on both stores. | Claude | Phase 2 criteria are in the plan. |

Phase 1 ends after three weeks only if crash-free sessions are 99.5% or better,
there has been no privacy incident, relay latency is within target and support is
manageable. Raise the TestFlight cap by re-running `public-link-enable` with a
larger `link_limit`; the Play audience has no numeric cap.

### F. Rollback

Do the first line that fits; the others can follow. Say on #861 what was done and
when.

| # | Step | Who | Verify |
| --- | --- | --- | --- |
| F1 | **Stop new iOS joins:** `TestFlight public link`, `action=public-link-disable`, apply on (no phrase needed). | Claude | `action=verify`, `expect_link=disabled`: "public link is disabled". |
| F2 | **Stop new Android installs:** Play Console > Testing > Open testing > **Pause track**. The API cannot do this and cannot see it (the `Close public Play tracks` workflow cannot halt a completed open-testing release either). | Operator | Open the opt-in page from a non-tester account: it no longer offers the app. Record the time on #861: nothing in this repository can observe it. |
| F3 | **Stop people who already have a build:** App Store Connect > TestFlight > the build > **Expire Build**; Play: release a fixed build to `beta` (same workflow, new number) or use the relay gate. | Operator | The build shows expired. |
| F4 | **Emergency cutoff for installed apps:** set `RIDE_RELAY_MINIMUM_CLIENT_BUILD_IOS` and `_ANDROID` above the broken build ([internet-relay.md](./internet-relay.md)): the relay refuses those builds with an Update required response. Redeploy the relay and check `/api/v1/compatibility`. | Claude | `minimumClientBuilds` lists both platforms; a build below it gets HTTP 426. |
| F5 | **Tell people:** a short status message on the website home page (a small PR) and a post in the groups from D10. | Operator | Live on `tailendcharlie.app`. |
| F6 | Relay problems follow the relay runbook (`docs/server-runbook.md`, Rollback). | Claude | `serverBuildCommit` and health. |

## Operator-only steps, in one list

Claude cannot do these, and will not change a store, a Console setting or a
repository variable.

1. **Play Console:** confirm Android Auto is **not** opted in under Form factors
   (B2). Set open testing to UK only with the feedback contact (B3).
2. **Play Console:** complete App content: privacy policy, ads, app access,
   content rating, **target audience** (recommended 16 to 17 and 18 and over),
   Data safety, foreground service declaration (B1).
3. **Play Console:** keep the open-testing track paused until D2, unpause it on
   launch day, and pause it again for any rollback (B4, D2, F2). The pause is
   visible only in the Console.
4. **Play Console:** paste the store listing text (B5) and check Publishing
   overview (C6).
5. **App Store Connect:** confirm the Beta App Review contact and reviewer notes
   (B7), watch Beta App Review (C2), and expire a build if one has to be stopped
   (F3).
6. **GitHub settings:** set `RIDE_RELAY_TESTFLIGHT_INVITE_URL` (D8).
7. **Decide** the Apple age-rating tier and the Play target audience, which both
   have to express a minimum age of 17 in scales that have no 17.
8. **Confirm** build `<N>` asks about heatmap contribution at setup with nothing
   pre-selected and contributes nothing until a rider chooses (#957), as the
   Data safety answer says, and that `testing@` reaches you.
9. **Post** the links to the first groups, and say "go" before each dispatch.
10. **Test as a stranger** on a real phone from each opt-in page (D3, D9).

## Not done, and why

- The public routing services are still named in `privacy.html` and `terms.html`.
  Those paragraphs belong to the routing cut-over (#917) so they change with the
  service, not before it.
- No in-app "leave and delete" action was added or verified; deletion by email and
  automatic expiry are what the policy says.
- No known-issues web page generated from `tester-release-notes.md`, and no
  written triage routine beyond the 48-hour rule above. Neither has a ticket yet.
- Android Auto and CarPlay are not claimed anywhere. #698 and #703 stay open.

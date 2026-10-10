# Open beta plan: iOS and Android

Written 4 October 2026, after the build 101 group ride and while build 102 is
being prepared. Start this plan once build 102 has been ridden by the tester
group and its validation checklist is complete.

## What "open beta" means

Anyone can install the app without being personally invited, and groups
organise their own rides without the operator present. It is still a beta,
not a store release.

| Platform | Mechanism | Who can join |
| --- | --- | --- |
| iOS | TestFlight external testing with a **public link** | Anyone with the link, up to a cap we set (TestFlight's maximum is 10,000 external testers) |
| Android | Google Play **open testing** track (`beta` in the API) | Anyone; the app is listed on Play as a beta, limited to the countries we choose |

Start in the **United Kingdom only**. That keeps the speed-limit, routing and
enforcement data within what has been field-tested. It also avoids the EU
trader-status and consumer-law obligations until there is a reason to take
them on.

## Where we start from

- **iOS:** an external TestFlight group exists. Builds 98–101 passed Beta App
  Review with the CarPlay navigation entitlement. Turning on a public link is a
  setting on that group.
- **Android:** closed testers are on `alpha`. The open-testing track exists: it
  was live by accident in July (see `android-internal-testing.md`) and was
  paused in the Console. Personal Play accounts created after 13 November 2023
  must earn production access, via a 12-tester, 14-day closed test, before open
  testing is offered. This app's track has served releases, so confirm in the
  Console that open testing is available and still paused before planning
  around it.
- **Relay:** one small cloud VM (under 1 GB RAM plus a 2 GB swapfile). It
  deploys automatically and is probed every five minutes by
  `relay-health.yml`, which opens an alert issue. It crashed silently on 5–6
  September, before that monitor existed.
- **Third-party services called directly from every phone.** These are the
  largest blocker. None is intended for an open public app:

| Service | Used for | Published limit |
| --- | --- | --- |
| OSRM demo server | Default routing | Non-commercial, reasonable use, at most 1 request/s, no uptime guarantee |
| FOSSGIS Valhalla | Motorcycle routing, speed limits, route validation | 1 request/s per user and 100/s in total; the operators say it is not usable for third-party production services. `maps-and-gpx.md` commits us to notifying them before any public tester rollout. |
| OSM Nominatim | Destination search | At most 1 request/s **per application** (all users combined), caching required, no autocomplete |
| OpenFreeMap | Map tiles | Free, fair use, donation-funded |

## Launch status (10 October 2026)

The operator decided the open questions on #861 and asked for the beta to be
launched. What is built and what is open, by gate. The day-of procedure, the
store answers and the rollback are in [open-beta-launch.md](./open-beta-launch.md).
**Built** means it exists in the repository and is tested; none of it has touched
a store. **Open** gates block the link.

| Gate | Status | Built | Still open |
| --- | --- | --- | --- |
| G1 Field quality | **Open** | The #855 evidence instrument is in; the listing says Bluetooth sharing is unverified and not to rely on it, so the "or do not imply it works" alternative is met. | Build 102 ridden by a mixed iOS and Android group: #839, #851, #853, #856, #616 and #859 are ready for validation, not validated. #855 and #268 need the airplane-mode check on real phones. Crash-free sessions of 99.5% or better from TestFlight and Play vitals: no data yet. |
| G2 Infrastructure | **Open** | Self-hosted routing stack and runbook (#926), app and web endpoint resolution (#927, #929) under #917. `build_number` is required and checked against both stores before any build (#630). The compatibility gate, screen and tests exist (#37). | Cut-over and smoke test of the routing service (#917); the remaining OSRM calls (#930). Relay hardening: load test on the real VM, backup and restore, an alert that reaches the operator's phone, ride-size and event-rate caps (#273); per-device authentication (#337) before the code space is exposed to strangers. #37 needs a real old TestFlight and Play build to have shown the screen against pre-production. #398, #421 and #352 are still open. |
| G3 Privacy, safety, legal | **Partly built** | Privacy policy and terms say beta, minimum age 17, push-notification tokens, and beta support; the terms say the emergency-stop alert reaches only the group, navigation is advisory and the phone is not to be handled while riding. Data safety, content rating, foreground-service and App Privacy answers drafted. | DPIA and retention decision (#338). Sharing stops after a group disperses (#859, ready for validation). The policy and terms still name the public routing services until cut-over. An in-app "leave and delete" action is not built; deletion is by email and expiry. The operator files the Play and App Store answers. |
| G4 Usable without the operator | **Open** | Onboarding (#42) and menu consolidation (#306) are ready for validation. **Email beta support** on About & build and **Beta support** in Settings send the build identity to the support address. The listing text cannot drift into Nearby, CarPlay or Android Auto claims (`tools/testflight/test_beta_listing.py`). | Planning-flow phase 1 (#847, in progress) and phases 2 to 6 (#891 to #899). Invitations end to end from `join.html` without the WhatsApp group. Wording drift (#626). Nothing attaches ride diagnostics to a support email automatically; a rider shares them from Settings. |
| G5 Platform reviews | **Built, awaiting reviews** | Android: the open-testing release needs a typed confirmation, refuses an Android Auto bundle, reads the track back, and builds without Android Auto (an explicit `-PandroidAuto=true` switch is off everywhere; no track has carried Android Auto since build 88). iOS: reviewer notes drafted; the `TestFlight public link` workflow opens, verifies and closes the link. | The Play Console check that **Android Auto is not opted in** (per app, not per track), and Play's own review of the open-testing release. Beta App Review of the build. #698 (CarPlay) and #703 (Android Auto) stay open and nothing claims either. |
| G6 Support | **Mostly built** | One address, **testing@tailendcharlie.app**, in the app, the website, the privacy policy, the terms and every listing. | A public known-issues page generated from `tester-release-notes.md`; a written triage routine (the 48-hour rule is in the launch doc). Neither has a ticket. |

Decisions recorded on #861 (9 and 10 October): self-hosted routing, a phase 1 cap
of 100, support at `testing@tailendcharlie.app`, minimum age 17, and Android
Auto left out of the open-testing build. The "Decisions needed" list below is
therefore answered except for two scale questions the stores force: Apple has no
17+ tier and Play's age bands are 16 to 17 and 18 and over.

## Gates: all must be true before the link goes public

### G1 Field quality: build 102 proven on a ride

- The build 102 validation checklist is complete on a real group ride, with
  iOS and Android riders.
- No navigation fault of the "carry straight on" class remains open (#851,
  #853, #856, #839).
- Bluetooth peer-to-peer is evidenced with the #855 instrument, including the
  airplane-mode check (#268). Alternatively, the app must not imply that it
  works.
- Store vitals for the tester builds show no crash cluster: TestFlight crash
  reports and Play Android vitals, crash-free sessions ≥ 99.5%.

### G2 Infrastructure that can take strangers

1. **Stop depending on the public demo servers.** Decided: self-host on an
   Oracle Always Free Ampere A1 VM, separate from the relay (#917). The runbook
   is [`routing-service.md`](routing-service.md). It covers provisioning,
   verification, cut-over, rollback and cost.
   - Valhalla (motorcycle and auto costing) and Photon for Great Britain,
     Ireland, the Isle of Man and France, behind Caddy with per-client rate
     limits and an `X-Client-Id` check. The stack is in `deploy/routing/`.
   - The relay advertises the service URLs in `/api/v1/compatibility`, so the
     app and the web planner move over without a release, and back again by
     unsetting them.
   - Oracle's A1 allowance is now **2 OCPU / 12 GB**, not the 4 OCPU / 24 GB this
     plan first assumed. The stack is sized to fit it at £0. Whatever A1
     capacity the relay uses comes out of the same allowance.
   - Valhalla can serve every routing call the app makes. Moving the remaining
     OSRM calls to Valhalla `auto` changes the routes riders get, so it is a
     follow-up that needs field validation (#930).
2. **Relay hardening.**
   - Load-test N concurrent rides of 10 riders on the real VM size and record
     the result.
   - Confirm the health monitor reaches the operator's phone within minutes,
     not just an issue nobody sees (#273).
   - Test backup and restore.
   - Enforce ride-size and event-rate caps.
   - Per-device authentication (#337) should land before the code guessable
     space is exposed to strangers.
3. **Version gate.**
   - Exercise `/api/v1/compatibility` end to end: an old beta build is told to
     update, with a link, rather than failing in confusing ways (#37). The
     per-platform minimum build, the screen and the tests exist; the gate stays
     open until a real old TestFlight and Play build has shown the screen
     against pre-production (see internet-relay.md).
   - The Android version code must not default to the run number (#630).

### G3 Privacy, safety and legal

- The privacy policy at `tailendcharlie.app/privacy` must describe what the
  beta actually does: live location sharing and its retention, relay storage
  and deletion, opt-in heatmap and ETA contributions, diagnostics, and Nearby.
- The DPIA and retention decision is complete (#338).
- Global heatmap contribution is opt-in and asked at setup (#957, operator
  decision of 10 October 2026). A rider who has not chosen contributes nothing;
  riders from before the question existed are asked once on the home map. The
  Data safety answer for approximate location says so.
- No phone keeps sharing for hours after a group disperses (#859).
- Terms with clear safety wording:
  - the app is not an emergency service;
  - SOS reaches only the group;
  - navigation is advisory;
  - do not handle the phone while riding.
- Minimum age matches UK motorcycle licensing (suggest 17+).
- A data-deletion route: an email address in the privacy policy, plus "leave
  and delete" in the app. Riders have no accounts, so Play's account-deletion
  rule should not apply. Confirm that against the Data safety form.
- Store declarations:
  - Play Data safety form;
  - background-location declaration with prominent in-app disclosure;
  - foreground-service (location) declaration;
  - the Nearby devices permission rationale.

  iOS needs App Privacy details only for App Store submission. Prepare them now
  anyway, from the same inventory.

### G4 Usable without the operator in the room

- First-run onboarding (#42) explains leader, Tail End Charlie and marker roles
  and why each permission is needed.
- One coherent way to plan, edit and convert a ride between solo and group
  (#847, at least phase 1).
- Invitations work end to end from `join.html` without the WhatsApp group.
- In-app feedback:
  - iOS testers have TestFlight's screenshot feedback;
  - Android needs a "Send feedback" action that opens an email or form and can
    attach the ride diagnostics.
- UI copy claims nothing beyond the evidence: Nearby, CarPlay, Android Auto and
  background behaviour (AGENTS.md project rules).

### G5 Platform reviews

- **TestFlight:** the first build of each new version needs Beta App Review.
  The test information needs a beta description, feedback email and privacy
  policy URL. The reviewer needs instructions to create and join a ride alone
  (Ride Lab works for this).
- **Android Auto:** open testing has a *blocking* Android for Cars quality
  review; closed testing's is non-blocking. If #703's review gate has not
  passed, either ship the open-track build without the Android Auto opt-in, or
  hold the open track. Otherwise a car-quality failure blocks the whole
  release.
- **CarPlay:** the TestFlight entitlement already works. Production support
  must still not be claimed until #698 passes.

### G6 Support

- One support address, monitored, and stated in the store listings and in the
  app.
- A public known-issues and release-notes page generated from
  `tester-release-notes.md`.
- A triage routine: new feedback becomes issues within 48 hours, using the
  existing labels.

## Rollout phases

| Phase | Audience | Cap | Exit criteria |
| --- | --- | --- | --- |
| 0. Gates | Current testers | — | G1–G6 complete |
| 1. Friends of riders | UK riding groups we know: Bike and Brew, existing testers' clubs | TestFlight link capped at 100; Play open testing, UK only | 3 weeks; crash-free ≥ 99.5%; no privacy incident; relay p95 sync latency within target; support load manageable |
| 2. Open UK beta | Anyone in the UK | 1,000 | 6 weeks of phase-1 criteria; routing and geocoding self-hosted and monitored |
| 3. Store release decision | — | — | Separate decision: App Store review, Play production, CarPlay/Android Auto production gates (#698/#703) |

Raise the TestFlight cap in steps. It can be lowered or disabled at any time.
Open testing on Play can only be paused **in the Console**, never through the
API (`android-internal-testing.md`). Write that into the incident runbook.

## Operating the beta

- **Cadence:** a tester build at most weekly, each with release notes and a
  relay deployed at the same commit (`serverBuildCommit` verified). Keep build
  numbers strictly increasing on both stores.
- **Telemetry stance:** no analytics SDK. Use store crash vitals, opt-in
  diagnostics shared by riders, and relay health metrics only. This keeps the
  privacy story simple.
- **Incidents:** the relay runbook (`server-runbook.md`), plus pausing the
  TestFlight link and the Play open track, plus a pinned status message on the
  website.

## Decisions needed from the operator

1. ~~Routing and geocoding: self-host on a free-tier ARM VM (recommended) or
   pay a hosted provider.~~ Decided: self-host (#917).
2. The phase 1 tester cap and the groups invited.
3. The support address, and whether there is a public community channel.
4. The minimum age.
5. Android Auto in the open-track build: hold it until #703 passes, or ship
   without it.

## Ticket map

| Gate | Tickets |
| --- | --- |
| G1 | #839, #851, #853, #856, #855, #268, #616 |
| G2 | #917, #273, #337, #37, #630, #398, #421, #352 |
| G3 | #338, #859 |
| G4 | #42, #847, #306, #626 |
| G5 | #698, #703 |
| G6 | (new work; ticket when the support address is chosen) |

Sources for the platform and service limits:

- [Nominatim usage policy](https://operations.osmfoundation.org/policies/nominatim/)
- [OSRM demo server policy](https://github.com/Project-OSRM/osrm-backend/wiki/Demo-server)
- [FOSSGIS Valhalla server limits](https://github.com/valhalla/valhalla/discussions/3373)
- [Play testing requirements for new personal accounts](https://support.google.com/googleplay/android-developer/answer/14151465?hl=en)
- [Play test tracks](https://support.google.com/googleplay/android-developer/answer/9845334?hl=en)
- [Distributing car apps](https://developer.android.com/training/cars/distribute)

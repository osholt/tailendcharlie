# Phase 0 field-test results

Evidence record for the protocol in [field-test-plan.md](field-test-plan.md), and
the artefact #268 and #269 close against. One section per run.

**Nothing in this file is evidence until it has a date, a build number and an
observed measurement.** A step with a blank result is not a passed step. Label
every run with the surface it was observed on — physical phone, iOS Simulator or
Android emulator — because a simulator or emulator result never satisfies a radio,
battery or real-GPS pass gate ([AGENTS.md](../AGENTS.md)).

Identify phones by model and OS version only. A UDID or serial number must never
be committed.

## Build and relay parity

Rule 0 of [build-and-run.md](build-and-run.md): the relay must be at the same
commit as any app build installed. Record both, per run.

| Field | Value |
| --- | --- |
| App build | `1.0.1` build `9003`, track `local`, test-control define **on** |
| App commit | `c5983fa` |
| Relay host | `relay.tailendcharlie.app` |
| Relay commit | **unverified** — needs host access, or a build stamp on an unauthenticated endpoint (#273) |
| Relay capability parity | 14 capabilities, matching this tree's `supported_capabilities` default |

## Run log

### 2026-07-31 — build installed on both iPhones

Status: **done.** A stamped Profile build is on both phones and verified at the
artefact level.

| Check | Result |
| --- | --- |
| Build | `1.0.1` build `9003`, track `local`, commit `c5983fa`, `RIDE_RELAY_TEST_CONTROL=true` |
| Signing authority | `Apple Development`, `TeamIdentifier=UY4624PH6X` |
| Embedded profile | `Tail End Charlie CarPlay Navigation Development` (expires 2027-07-29) |
| Entitlements | `carplay-driving-task`, `carplay-maps`, `aps-environment => development`, `applinks:tailendcharlie.app` |
| Installed — iPhone SE 3rd gen, iOS 26.1 | `app.tailendcharlie` 1.0.1 (9003) |
| Installed — iPhone 15 Pro, iOS 26.5.2 | `app.tailendcharlie` 1.0.1 (9003) |

Two notes for the next person. The 15 Pro is paired over the network, not USB —
`system_profiler SPUSBDataType` lists no iPhone on the bus — and its first
`devicectl install` failed with `NWError 54, connection reset by peer`. An
immediate retry succeeded. A cable avoids this; see the symptom index in
[build-and-run.md](build-and-run.md).

The **About & build** confirmation in
[build-and-run.md](build-and-run.md) still needs doing on each phone by hand.
`devicectl device info apps` confirms the bundle version but cannot show what the
app reports for distribution track or relay host, which is the half that catches
a missing `--dart-define`.

### 2026-07-31 — step 8b, idle-device delivery (#132, #134, #99)

Status: **sub-steps 1–3 pass.** Driven through the test-control surface
(`tools/field-test-8b.sh`) rather than tapped, so the delays are measured rather
than estimated.

| Field | Value |
| --- | --- |
| Build | `1.0.1` (9005), track `local`, `RIDE_RELAY_TEST_CONTROL=true` |
| App commit | `c5983fa` plus the uncommitted test-control work |
| Leader | iPhone 15 Pro, iOS 26.5.2 |
| Follower | iPhone SE 3rd generation, iOS 26.1 |
| Transport | internet relay (`relay.tailendcharlie.app`) |
| Ride | `397676` |

| # | Sub-step | Result | Observed delay |
| --- | --- | --- | --- |
| 1 | Leader creates, follower joins, leader starts | **pass** | — |
| 2 | Both untouched two minutes; reconciliation read on both | **pass** — leader `roster=2 placed=1 gate=true`; follower identical | — |
| 3a | Hazard from follower only → leader shows it having sent nothing itself | **pass** | **336 ms** |
| 3b | Same in the other direction | **pass** | **330 ms** |
| 4 | Roles swapped (SE leads), 1–3 repeated | **pass** — `roster=2 placed=2 gate=true` on both; ride `865921` | **2476 ms** / **2568 ms** |
| 5 | Clock five minutes wrong, each direction | **not run** — an OS setting, not drivable from the surface | — |

**On sub-step 2's `placed=1` with `roster=2`.** Both phones were stationary
indoors, so the remote rider had never reported a position and sits in
`awaitingFirstFix`, which satisfies the gate. An earlier version of the
reconciliation counted that as the #132 signature and failed a healthy ride; see
the note in `test_control_snapshot.dart`.

**On the delays.** An earlier attempt in the same session reported
`follower -> leader 1299 ms` and then `leader -> follower NO DELIVERY within 60s`.
That one-way failure was **not real**: both directions were sent to identical
coordinates, and `HazardDeduplicator` merges same-type reports within 75 m, so the
second was absorbed into the first and the count being watched never moved. The
measurement now tracks a specific hazard id with the two directions ~2 km apart,
and both deliver. Recorded here because a plausible-looking one-way delivery
failure is exactly the kind of false evidence a driven test can manufacture.

**On the spread between runs.** The four measurements were 336, 330, 2476 and
2568 ms — an eight-fold range. That is expected rather than unstable:
[server-architecture.md:114](server-architecture.md) documents four-second
polling, so an event's delay depends on where in the receiver's poll cycle it
lands, and everything observed falls inside one cycle plus network time. The
10-second gate therefore has roughly a 2.5× margin over the worst case seen. It
also means a *push* channel is the only way this gets materially faster, which is
worth knowing before anyone treats ~2.5 s as a defect.

**Sub-step 4 is a genuine pass, not a repeat.** The requirement is that the result
must not follow the role or the device. With the SE leading instead of the 15 Pro,
both directions still delivered and both phones still agreed — and `placed=2`
rather than `placed=1`, because by then both riders had reported a position.

**What this is evidence for.** Both devices are iOS and the transport was the
internet relay, so this speaks to #99, #132 and #134 — an idle device *does*
receive, without having anything of its own to send, within one poll cycle. It is
**not** evidence for radio, battery or real GPS, and does not touch the Nearby
path at all.

### 2026-07-31 — roster/presence agreement on a live two-rider ride (#132)

Status: **gate passes.** Read from a real in-progress ride on the iPhone 15 Pro
(iOS 26.5.2, build 9003) via `/v1/state`, with a second rider on another phone.

| Reconciliation field | Value |
| --- | --- |
| `rosterCount` | 2 |
| `presenceCount` | 2 |
| `withPosition` | both riders |
| `countedWithoutPositionOrReason` | **empty** |
| `placedButNotInRoster` | empty |
| `gateSatisfied` | **true** |

So the #132 signature is **not present** in this ride: every counted rider is also
placed. That is the first real-hardware evidence for that gate.

Two things in the same snapshot are worth following up, and neither is what this
step was looking for:

**The live presence channel is contributing nothing.** Both riders' `sources` are
`['journal']` — the local device additionally has `localDevice`. Neither carries
`internetPresence`, so positions are arriving only as journal events and the
ephemeral `live-presence-v2` channel is not delivering. That is the shape of #99
and #134 and should be checked against them.

**Both riders read stale, including the local one.** The local device's own
position was 165 s old and the remote rider's 875 s. A phone that is not in the
foreground stops producing fixes, which is #205, and it is the same cause as the
"Updates delayed" line on the safety-contact page.

### 2026-07-31 — step 18, observer map style (#274)

Status: **run, and it fails.** The deployed relay returns **404** for
`/maps/styles/ride-relay.json`, which is the style
[observer.js:20](../apps/website/observer.js) asks for. MapLibre errors, the page
falls back to `#map-empty`, and a safety contact sees only
`Last known: <lat>, <lon>`.

Per step 18 this is the documented outcome when the operator archive and style are
absent, so it is recorded as **observer map unavailable** rather than as a code
fault. It does mean the safety-contact feature is not usable as intended today —
see #274.

Observed alongside it: an empty red assistance alert with no text, filed as #278.

### 2026-07-31 — iPhone↔iPhone subset

Status: **not yet run.** Steps 3, 4, 5, 6, 8, 9, 10, 11, 13, 14, 16, 17, 20, 21,
plus step 1's iPhone↔iPhone pairing and 8a's internet-only leg.

### Early August 2026 — Android session with the tester group

Status: **scheduled, hardware not owned.** Steps 1 (Android pairings), 2, 7
(nearby and mixed transports), 12, and the Android halves of 15 and 16.

One pass only — it depends on other people's phones and time. Rehearse on the
iPhone pair first so the session collects evidence rather than working out
procedure.

## Pass gates

Carry each gate from [field-test-plan.md](field-test-plan.md) here as it is
measured, with the measurement beside it. A gate with no measurement is a fail,
not a blank.

| Gate | Measurement | Verdict |
| --- | --- | --- |
| 95% of priority events reach an in-range peer within 10 s | 4/4 hazards delivered, 330–2568 ms — but over the **relay**, not an in-range peer | partial (relay only) |
| No duplicate marker count after 100 event replays | | |
| Queued events converge without user repair after peers reunite | | |
| A phone with nothing to send still receives; idle phone never behind by more than one poll interval plus one retry | 4/4 delivered to a receiver that had sent nothing; worst 2568 ms, inside one 4 s cycle | **pass** (iOS↔iOS, relay) |
| Rider count equals drawn markers plus riders whose row states why they have no position | `gateSatisfied: true` on both phones across three rides, and on a live two-rider ride | **pass** (iOS↔iOS) |
| Two phones with disagreeing clocks still show each other live | | |
| A position that stops updating is demoted to ageing then stale in wording as well as colour | | |
| Four-hour screen-off consumption within the 45% planning limit | | |

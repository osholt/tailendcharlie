# Offline Group Riding App — Product and Delivery Plan

Status: development alpha implemented; physical-device and production gates open
Working title: **Ride Relay** (placeholder; naming is not part of MVP)
Initial market: UK motorcycle groups using the second-bike drop-off system
Platforms: iOS and Android

## Implementation status

The repository now contains an integrated development alpha:

- shared Flutter application plus native Swift and Kotlin shells;
- persistent anonymous ride sessions;
- an idempotent SQLite event journal and versioned event envelope;
- HMAC-tagged ride, role, marker, and priority-message events;
- QR/deep-link invitations and a gloves-oriented development UI;
- GPX 1.1 import, persistent route geometry, offline route display, and a
  provider/licence-gated map-corridor tile cache;
- foreground position capture, group/hazard overlays, rider-created hazard
  events, stale-GPS handling, and hysteresis-based route-deviation alerts;
- an authenticated, bounded, durable store-and-forward relay protocol with
  ACKs, expiry, deduplication, reconnect backoff, and native Google Nearby
  Connections implementations for Android and iOS;
- a disabled-by-default HTTPS sync client with bounded idempotent batches,
  opaque cursors, authenticated downloads, and automatic retry;
- conservative marker suggestions requiring explicit confirmation,
  authenticated unique-pass/TEC evidence, and marking-time summaries;
- GPX sharing, documented Google Maps/Waze handoffs, share-sheet handoff for
  Calimoto/MyRoute/Garmin/BMW, and CSV/text ride summaries;
- an active-ride shell joining Ride, Map, and Awareness around the same event
  journal; and
- CI definitions for analysis, tests, Android debug APKs, and unsigned iOS apps.

The remaining P0 gates require evidence or external systems rather than more UI
claims: physical Android/iPhone radio and background testing, foreground-route
alert calibration, battery testing, production identity/encryption and
retention, a provisioned production relay server, and field-tested marker/pass
detection. A licensed basemap/traffic provider is not configured. Waze is
explicitly unavailable as a general hazard-read source. Manual six-character
joining cannot start authenticated nearby or internet relay because it does not
carry the high-entropy invitation secret; QR/deep-link joining is the supported
alpha path.

## 1. Product summary

Ride Relay keeps a motorcycle group coordinated where mobile coverage is poor.
It combines an internet connection with direct phone-to-phone Bluetooth/Wi-Fi
communication, automatically relays small ride events through nearby riders,
works from a route/map downloaded before departure, and requires very little
interaction while riding.

The app is not intended to replace a full motorcycle navigation product. It is
the group's coordination and safety layer and can hand a known route to Waze,
Calimoto, MyRoute-app, BMW Connected, Garmin, and other navigation products.

## 2. Problem statement

Existing group-location apps become least reliable on the rural roads where
motorcyclists most need them. The second-bike drop-off system works socially,
but leaders and markers cannot reliably know who has passed, whether someone
missed a junction, or whether a message has reached the rest of the group.

The rider needs confidence that essential state will survive loss of signal,
move between nearby phones without manual pairing during the ride, and reach the
server automatically when any rider regains connectivity.

## 3. Product principles

1. **Gloves on, eyes up.** A rider should normally interact only before setting
   off or while stopped. Moving interactions use audio, haptics, or one large
   control.
2. **Offline is a normal state.** Every important action is first committed to
   the phone, then synchronised over whatever transport is available.
3. **No false certainty.** The UI distinguishes confirmed, relayed, stale, and
   unknown information.
4. **No account required for MVP.** A ride code or QR invitation creates an
   ephemeral identity and encrypted ride membership.
5. **Privacy expires with the ride.** Precise live locations are retained only
   for the active ride plus a short recovery window. End-of-ride statistics are
   opt-in and may be stored without a full location history.
6. **Degrade gracefully.** Loss of internet, loss of a peer, denied Bluetooth,
   or an unavailable map must not crash or freeze the ride.

## 4. Goals

- A group of 5–30 riders can create and join a ride in under two minutes.
- Group progress, marker events, and essential messages continue when all phones
  lose mobile data but at least some riders periodically come within peer range.
- A marker can see a reliable unique count of riders that passed and know when
  the Tail End Charlie has passed.
- A rider receives a local warning after a sustained route deviation even with
  no connectivity.
- Queued events recover automatically when a peer or internet path becomes
  available, without opening a repair screen or resending manually.
- A known route and its map corridor are usable offline and shareable to common
  navigation apps with the smallest practical number of taps.

## 5. Non-goals for the first public version

- **Full turn-by-turn navigation.** Existing navigation apps already do this
  well; MVP displays route context and off-route warnings.
- **Live voice intercom.** Cardo/Sena-class audio is a different reliability and
  hardware problem. MVP supports preset messages and queued voice notes later.
- **Reading Waze crowd hazards.** Waze has no general public read API for its
  live user reports. Waze partnership is an optional enhancement, not a launch
  dependency.
- **Guaranteed operation after force-quit.** iOS does not permit a promise of
  continuous peer discovery after the user terminates the app.
- **Public social network, ride discovery, profiles, or feeds.** These dilute
  the coordination problem and add moderation/privacy work.
- **Automatic emergency-service contact.** False positives and regional legal
  requirements make this a separate safety project.

## 6. Personas and core user stories

### Ride leader

- As a leader, I want to start a private ride with a short code or QR invitation
  so the group can join without accounts.
- As a leader, I want to see the last confirmed progress of every rider and the
  freshness/source of that information so I do not mistake stale data for live
  data.
- As a leader, I want alerts when a rider persistently deviates, stops, or falls
  substantially behind so I can decide whether to stop the group.

### Marker

- As a rider stopping at a decision junction, I want the app to suggest marker
  mode automatically so I do not need to operate a small control.
- As a marker, I want each rider counted once and the Tail End Charlie clearly
  identified so I know when to rejoin.
- As a marker, I want the count to survive temporary disconnections and reconcile
  later so a brief radio failure does not corrupt the ride record.

### Rider and Tail End Charlie

- As a rider, I want a private audio/haptic warning when I appear to have missed
  the route so I can correct before becoming separated.
- As a rider, I want one-tap stopped/fuel/mechanical/assistance messages that are
  delivered when connectivity returns.
- As Tail End Charlie, I want markers to receive a positive, authenticated
  indication that I passed rather than inferring it from an anonymous Bluetooth
  signal.

## 7. MVP scope and acceptance criteria

### P0 — required for a private field-test release

#### Ride lifecycle and roles

- Create/join/leave/end ride using a QR code or six-character code.
- Roles: Lead, Rider, Tail End Charlie, Marker.
- Ephemeral device key pair and ride-scoped identity; no email/password.
- A reconnecting device resumes its previous ride state.

Acceptance:

- Ten test phones can join the same ride in under two minutes.
- Reinstalling or joining from an uninvited device does not reveal the ride.
- Ending a ride prevents further live-location exchange and starts the retention
  deletion timer.

#### Hybrid event transport

- Every important change is an immutable event stored locally before sending.
- Internet and nearby-peer transports may operate simultaneously.
- Events have unique IDs, signatures, timestamps, priority, expiry, and delivery
  acknowledgements.
- Peers exchange missing events and may carry them to other group members.
- Duplicate and out-of-order delivery is safe.

Acceptance:

- With mobile data disabled, two iPhones, two Android phones, and a mixed pair
  exchange priority events while the apps remain in an active ride.
- A message created offline reaches the server automatically after any carrying
  phone regains internet.
- Replaying the same event 100 times does not duplicate a marker count, message,
  or alert.
- The UI shows `live`, `relayed`, `stale`, or `unknown`; it never silently labels
  old location data as current.

#### Location and group progress

- Record location and progress while an active ride is running.
- Display the group's latest known positions and connection freshness.
- Produce compact progress beacons suitable for nearby relay.
- Reduce update rate when stopped and under battery pressure.

Acceptance:

- On the reference phone set, 95% of internet-connected position events are
  visible to the leader within 5 seconds.
- While peers are in direct range without internet, 95% of priority progress
  events arrive within 10 seconds.
- Four hours of screen-off tracking consumes no more than 45% battery on each
  reference phone after the test battery-health threshold is applied.

#### Offline route pack

- Import GPX 1.1 route/track data.
- Store the route, decision junctions, and an offline map corridor before riding.
- Show download state and estimated storage; warn before departure if incomplete.
- Continue route display and deviation calculation without internet.

Acceptance:

- Flight mode does not remove the route or map from an already prepared ride.
- A corrupt or unsupported GPX file produces a useful error and does not create a
  partial ride.
- The user can delete downloaded ride data explicitly.

#### Marker assistance and counting

- Detect a probable marker when a rider stops near a decision junction while the
  group continues, then give a haptic/audio suggestion with a large cancel action.
- Count unique ride identities whose route progress crosses the marker line.
- Display expected riders, confirmed passes, uncertain passes, and TEC passage.
- Allow manual marker start/end as a reliable fallback.

Acceptance:

- In a controlled 10-rider pass, the final reconciled count is at least 95%
  accurate and never counts a rider twice.
- Riding slowly through a junction without stopping does not enter marker mode.
- A U-turn or repeated pass does not increment the unique-rider count.
- The marker can end or cancel an incorrect detection without navigating menus.

#### Off-route and separation alerts

- Compare the phone's own GPS fix with the offline route corridor.
- Require sustained deviation using accuracy, distance, direction, and time to
  reduce false alarms.
- Warn the rider privately before notifying the leader/TEC.
- Queue and relay escalation events if the deviation persists.

Acceptance:

- No alert is generated solely by a low-accuracy GPS fix.
- The reference test route detects a deliberately missed turn within 60 seconds.
- False warnings remain below one per 10 rider-hours during beta field rides.

#### Essential communications

- Presets: stopped, mechanical, fuel, assistance needed, route blocked, emergency
  stop, all riders passed, and resolved.
- Messages persist locally, show delivery state, expire appropriately, and relay
  through peers.
- High-priority alerts use audio/haptics and cannot be mistaken for confirmed
  delivery when still queued.

Acceptance:

- A queued message survives app restart and is delivered once a path exists.
- A rider can send an essential preset using at most one confirmation after
  selecting it, with a stationary-mode large-control UI.

### P1 — public beta / fast follow

- GPX 1.1 route-plus-track export via the native share sheet.
- Targeted hand-off to Calimoto, MyRoute-app, Garmin Drive/Tread, BMW Connected,
  and a simplified Google Maps/Waze destination link.
- End-of-ride marking statistics and an exportable ride summary.
- Group-created hazard reports with expiry and peer relay.
- Short recorded voice notes; no continuous voice channel.
- CarPlay and Android Auto companion surfaces, subject to platform entitlement.
- Leader-configurable alert sensitivity and planned regroup points.
- Optional account for saved groups/routes, while anonymous rides remain.

### P2 — future considerations

- Waze Transport SDK partnership for app switching and limited route/ETA data.
- Licensed roadworks, closure, camera, and traffic feeds.
- Hardware handlebar/helmet controls.
- Satellite messaging handoff where supported by platform APIs.
- Multi-day rides, organisations, subscriptions, and fleet administration.
- Crash detection and emergency workflows after dedicated safety validation.

## 8. Technical direction

### Client

- **Flutter** for the shared rider UI and domain logic.
- Native **Swift** and **Kotlin** modules for Nearby Connections, background
  execution, audio/haptics, CarPlay/Android Auto, and platform-specific location
  behaviour.
- **SQLite** as an append-only local event store plus materialised read models.
- A map-provider abstraction. Start with an SDK that explicitly licenses offline
  regions; do not assume ordinary web-map tiles may be bulk downloaded.

Flutter is a working recommendation, not an irreversible decision. Phase 0 must
prove that native nearby/background integrations remain reliable through its
platform channels before the production choice is locked.

### Nearby network

- Google Nearby Connections `cluster` strategy for encrypted Android/iOS peer
  connections over Bluetooth/Wi-Fi.
- The app-level protocol provides ride authentication, signatures, deduplication,
  priorities, expiry, acknowledgements, and store-and-forward relay.
- Nearby Connections is a transport, not the source of truth. The local event log
  remains authoritative for the device.
- Prioritise emergency/marker/message events over dense location history.

### Backend

- Small stateless API and WebSocket service, initially **FastAPI**.
- PostgreSQL/PostGIS for active rides, event ingestion, route metadata, and short
  retention jobs.
- Object storage for GPX/route packs if required.
- Redis is optional until load testing demonstrates a need.
- Server accepts idempotent event batches and never assumes continuous sockets.

### Security and privacy

- Ride invitation contains a high-entropy secret behind the human-readable code.
- Device-generated key pairs and signed ride events.
- Transport encryption plus application-layer encryption for sensitive messages.
- Rate limits and ride-size caps to resist code guessing and event floods.
- Automated deletion with auditable retention jobs.
- Emergency details remain on devices and are shared only with authorised ride
  roles; they are excluded from analytics and ordinary logs.

## 9. Architecture sketch

```text
                    internet available
 Phone A  <--------------------------------->  Ride API / event store
    ^                                                   ^
    | nearby encrypted event exchange                  |
    v                                                   |
 Phone B  <----->  Phone C  <----->  Phone D ----------+
    |                |                 |
 SQLite log       SQLite log        SQLite log

Every arrow may disappear temporarily. Each phone commits locally first,
deduplicates by event ID, and retries automatically when an arrow returns.
```

## 10. Delivery plan

### Phase 0 — feasibility spike (2–3 weeks)

Build a throwaway four-device prototype before the full application:

1. Swift and Android Nearby Connections examples using the same service ID.
2. Mixed-platform discovery, authentication, small event exchange, and reconnect.
3. Screen locked, app foreground/background, intermittent contact, and force-quit
   behaviour recorded separately.
4. Phones in jacket pockets/top boxes, moving past at realistic speeds.
5. Four-hour GPS/Bluetooth battery test.

Go/no-go gate:

- Proceed with phone-only mesh if foreground/active-ride behaviour meets the P0
  delivery target on the supported device set.
- If iOS background constraints make this unreliable, retain offline queues and
  opportunistic peer exchange but narrow product claims. Do not hide the limit.

### Phase 1 — private alpha (8–12 weeks after Phase 0)

- Project foundations, automated builds, crash reporting, and privacy-safe logs.
- Ride creation/joining, roles, local event log, and internet sync.
- Nearby transport and priority event relay.
- Location/group map, GPX import, offline route pack.
- Manual marker mode, authenticated counting, essential preset messages.
- Local off-route warning.

Alpha exit gate: two supervised rides of at least 10 riders and two hours each,
including a planned no-signal section, complete without lost priority events or
manual database repair.

### Phase 2 — field beta (6–8 weeks)

- Automatic marker suggestion and reconciliation.
- Leader/TEC alert escalation and end-of-ride statistics.
- GPX exports and navigation-app handoffs.
- Battery, reconnect, accessibility, and poor-GPS hardening.
- Closed TestFlight/Play testing across at least 50 riders and 20 ride sessions.

Beta exit gate: success metrics below meet threshold and every safety-critical UI
has been tested while stationary with gloves and via audio/haptics while moving.

### Phase 3 — public v1 (4–6 weeks)

- Store compliance, support tooling, retention verification, threat review.
- Onboarding that clearly explains permissions and force-quit limitations.
- Operational dashboards based on anonymous reliability metrics.
- Incident runbook and staged rollout.

Indicative total with two mobile engineers plus part-time backend/design/QA:
**5–7 months**. A capable solo developer should plan approximately **9–15 months**
including field testing. These are planning ranges, not commitments.

## 11. Success metrics

### Leading reliability metrics

- 95% of invited riders join successfully without support.
- 95% of nearby priority events reach an in-range peer within 10 seconds.
- 99.9% of accepted events are eventually deduplicated and converged across the
  server and participating devices.
- At least 95% final marker-count accuracy in field tests.
- Fewer than one false off-route alert per 10 rider-hours.
- 99.5% crash-free active-ride sessions.

### User outcome metrics

- 80% of beta rides complete without an unplanned stop to locate a rider.
- 80% of beta leaders report greater confidence than their existing drop-off
  process alone.
- 60% of beta groups use the app again within 30 days.
- Fewer than 5% of completed rides generate a connectivity-related support issue.

Metrics must never collect a permanent precise ride history by default. Reliability
telemetry uses coarse, ride-scoped, pseudonymous counters.

## 12. Major risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| iOS suspends discovery/background work | Mesh is less automatic than promised | Phase 0 device tests; honest active-ride/force-quit UX; opportunistic relay |
| Phones in pockets have poor radio/GPS | Missed passes and stale positions | Multi-signal reconciliation; uncertain state; field-test device matrix |
| Battery drain | Riders disable the app | Adaptive sampling; compact events; four-hour battery gate |
| False safety alerts | Loss of trust/distraction | Private-first escalation; accuracy/time/direction thresholds; easy resolve |
| Waze/hazard licensing unavailable | Feature gap | No MVP dependency; Waze deep links; group-reported and licensed sources later |
| Route differs after import | Rider follows a different path | Include route and track; preview before ride; preserve source geometry |
| Anonymous ride codes are guessed | Location disclosure | High-entropy invitation secret, rate limits, encryption, short expiry |
| Two apps compete for audio/location | Poor Waze/helmet experience | Early coexistence tests; preset audio policy; native integration boundaries |

## 13. Decisions needed before production implementation

Blocking after Phase 0, not before it:

- Supported minimum iOS/Android versions and reference-device matrix.
- Whether the Phase 0 results justify claiming `mesh` or the more precise
  `nearby relay` in product language.
- Map/offline tile provider after licence and cost comparison.
- Exact active-ride retention period and UK GDPR assessment.
- Whether public v1 requires CarPlay/Android Auto or ships without them.

Non-blocking:

- Final name and visual identity.
- Subscription model.
- Waze Transport SDK application outcome.
- Which licensed hazard provider, if any, is used after v1.

## 14. First implementation backlog

1. Create a four-phone field-test protocol and reference-device matrix.
2. Prototype Swift Nearby Connections advertising/discovery and byte messages.
3. Prototype Android Nearby Connections using the same cluster service.
4. Measure reconnect/background/locked-screen behaviour and battery.
5. Define the versioned ride-event envelope and threat model.
6. Scaffold the mobile app and local event store only after the spike passes.
7. Implement create/join ride and idempotent server batch sync.
8. Add nearby transport behind the same event-outbox interface.
9. Add group progress, GPX import, and offline route pack.
10. Run the first walking/driving simulation before any motorcycle field ride.

## 15. Reference constraints verified during planning

- Nearby Connections supports Android/iOS cross-platform communication without
  internet and offers a cluster topology for small mesh-like payload exchange:
  <https://developers.google.com/nearby> and
  <https://developers.google.com/nearby/connections/strategies>
- Waze Transport SDK is partnership-gated and does not expose embedded maps,
  server-side traffic reports, or fleet-management functionality:
  <https://developers.google.com/waze/intro-transport>
- Waze Deep Links are the non-partner fallback:
  <https://developers.google.com/waze/deeplinks>
- Mapbox documents offline-region support on both mobile platforms; final map
  choice remains a commercial/licensing decision:
  <https://docs.mapbox.com/playground/offline-estimator/>
- Google Maps URLs have waypoint and URL-length constraints, so they cannot be
  treated as faithful export for every motorcycle route:
  <https://developers.google.com/maps/documentation/urls/get-started>

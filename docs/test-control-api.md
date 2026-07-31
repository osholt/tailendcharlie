# Driving the app for a field test

A build can carry an HTTP surface that lets another machine create rides, join,
start, report hazards, inject positions and read the roster. It exists so the
sequences in [field-test-plan.md](field-test-plan.md) can be driven and, more
importantly, **measured**.

## Why it exists

Step 8b asks for the delay between a hazard leaving one idle phone and appearing
on another. Two things make that unmeasurable by hand:

- the assertion is about phones sitting **untouched**, and picking one up to read
  it ends the condition under test; and
- the answer is a number in seconds, in each direction, which nobody produces
  reliably while watching two screens.

The field failure behind #132 was reported as "it started working when I touched
it". That sentence is the defect, and a person holding the phone cannot
distinguish it from a recovery.

## It is not compiled into ordinary builds

Three gates, in order:

1. **Compile time.** `TestControlConfiguration.enabled` is a `const` read of
   `RIDE_RELAY_TEST_CONTROL`. Without the define the server, its routes and its
   snapshot assembly are tree-shaken out. A release build cannot be talked into
   serving this, because the code is not in it.
2. **In-app switch.** **Settings → Field test control**, off by default. The row
   says in plain words that another machine can drive the app - a rider who finds
   it switched on should not have to infer that from the word "debug".
3. **Bearer token.** Minted when the switch goes on and again on every app
   restart, shown in the app, required on every request but `/v1/health`. The
   switch turns itself off after 30 minutes with no authenticated request.

The first gate is asserted by
`test/services/test_control_server_test.dart`, which runs without the define
exactly as CI and a release build do. If that test ever fails, a shipped build can
be driven by anyone who can reach the phone.

## What it will never do

Enforced in `TestControlServer._handle` before routing, and listed in
`testControlForbiddenActions`:

| Excluded | Why |
| --- | --- |
| SOS and emergency actions | The point of an emergency control is that a human meant it |
| Emergency-contact and ICE disclosure | Someone else's data |
| Sharing a rider's own phone number | Same |
| Placing calls, sending messages | Reaches a phone network and a person |

If one of these needs coverage it belongs in a widget test against a fake, not
behind a network port on a real phone.

## Building and switching on

```bash
set -a; eval "$(tools/build-identity.sh apps/mobile/pubspec.yaml local 9001)"; set +a
cd apps/mobile
flutter build ios --profile \
  --dart-define=RIDE_RELAY_TEST_CONTROL=true \
  --dart-define=RIDE_RELAY_APP_VERSION="$RIDE_RELAY_APP_VERSION" \
  --dart-define=RIDE_RELAY_APP_BUILD="$RIDE_RELAY_APP_BUILD" \
  --dart-define=RIDE_RELAY_DISTRIBUTION_TRACK="$RIDE_RELAY_DISTRIBUTION_TRACK" \
  --dart-define=RIDE_RELAY_BUILD_TIMESTAMP="$RIDE_RELAY_BUILD_TIMESTAMP" \
  --dart-define=RIDE_RELAY_API_BASE_URL=https://relay.tailendcharlie.app/api
```

Then on the phone: **Settings → Field test control → Allow another machine to
drive this app**, and copy the token. Port `8477`.

The listener is dual-stack (`anyIPv6`, `v6Only: false`), which matters for how you
reach it. Xcode's CoreDevice tunnel to a paired phone is IPv6-only, so a paired or
cabled phone can be driven at its tunnel address — `xcrun devicectl list devices`
gives the hostname — with **nothing listening on the shared Wi-Fi network**. Use
the LAN address only when no tunnel exists.

Rule 0 of [build-and-run.md](build-and-run.md) still applies - the relay must be
at the same commit as the build being driven, or a driven test will faithfully
measure a server-side bug and report it as an app one.

## Routes

`Authorization: Bearer <token>` on everything except `/v1/health`.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/v1/health` | Liveness. Unauthenticated, and says nothing about the ride |
| `GET` | `/v1/state` | The snapshot below |
| `GET` | `/v1/ride/invite` | `rideCode` and `joinToken`. Capability material, so a separate explicit read |
| `POST` | `/v1/ride` | `{"displayName":"..."}` |
| `POST` | `/v1/ride/join` | `{"rideCode":"123456","displayName":"...","joinToken":"..."}` |
| `POST` | `/v1/ride/start` | — |
| `POST` | `/v1/ride/leave` | — |
| `POST` | `/v1/ride/end` | — |
| `POST` | `/v1/role` | `{"role":"lead"｜"marker"｜"tailEndCharlie"｜"rider"}` |
| `POST` | `/v1/hazard` | `{"type":"roadworks","severity":"caution","latitude":51.2,"longitude":-2.4}` |
| `POST` | `/v1/location` | `{"latitude":51.2,"longitude":-2.4,"accuracyMeters":5}` |

Every mutation answers with the post-action snapshot, so a driver measuring a
delay does not need a second round trip.

Errors: `400` malformed request, `401` missing or stale token, `403` an excluded
action, `409` no active ride, `404` unknown route.

## The snapshot, and why it is shaped this way

`/v1/state` reports the roster and live presence as **two independent
derivations**, then names where they disagree.

`RideController.participants` comes from `RideMembershipReducer` over the event
journal. `SituationalAwarenessController.livePresenceAt` comes from the presence
channel. #132 was a divergence between them: the leader counted the follower and
simultaneously showed them inactive with no position.

**A snapshot that merged them would have reported a healthy ride throughout that
failure.** The automation would then have manufactured false evidence, which is
worse than having none. So `reconciliation` reports:

| Field | Meaning |
| --- | --- |
| `rosterCount` | Riders in the roster, excluding those who have left |
| `presenceCount` | Riders the presence channel knows about |
| `withPosition` | Counted and placed |
| `withoutPositionButExplained` | Counted, no position, but a presence row that can state why. Satisfies the gate |
| `awaitingFirstFix` | Counted, has **never** reported a position. The normal state between joining and the first fix. Satisfies the gate |
| `countedWithoutPositionOrReason` | **The #132 signature.** Counted with neither a position nor a reason |
| `placedButNotInRoster` | The mirror image: a marker for someone the roster does not admit to |
| `gateSatisfied` | Both lists above empty |

`awaitingFirstFix` exists because of a false positive found by driving a real
ride rather than by reasoning about it. At ride start every rider is in the roster
and nobody has reported a position yet, and an earlier version of `reconcile`
called that a counted-without-reason rider and failed the gate on a healthy ride.
An automated run would have reported a #132 recurrence that was not there — the
exact failure this surface exists to avoid. The discriminator is whether the
rider has **ever** reported a position: never-reported is starting up, reported
then vanished with no explanation is the real fault.

`presence[]` also carries `clockBasis` and `publisherClockOffsetSeconds`, which is
sub-step 5 of 8b: a peer whose clock is five minutes wrong must still read as
live, with the offset named.

No invite secret, join token, phone number or ICE data appears in a snapshot. It
is meant to be safe to paste into
[field-test-results.md](field-test-results.md).

## Running step 8b

```bash
tools/field-test-8b.sh LEADER_HOST LEADER_TOKEN FOLLOWER_HOST FOLLOWER_TOKEN
```

Creates the ride, joins, starts, waits two minutes without touching either
device, reports the reconciliation on both, then measures hazard delivery in each
direction by polling **only the receiver** - so a device that needs an outbound
event of its own to make progress times out rather than appearing to work.

Sub-step 4 is the same script with the two pairs exchanged. Sub-step 5 needs the
OS date-and-time setting changed by hand.

## The app must be in the foreground

**iOS suspends a backgrounded app, and a suspended app stops accepting
connections.** Found the hard way: mid-run one phone's surface simply vanished —
`connection refused`, while the other stayed up — because the app was no longer
frontmost.

Consequences for a driven run:

- Both phones need the app open and the screen awake for the whole run. For step
  8b that is compatible with the protocol, which already says "both phones awake
  with the map open", but it does mean the screen cannot be allowed to lock. The
  active-ride wake lock (#50) is doing that job, and if it fails the run dies with
  it.
- A dropped surface is indistinguishable from a crashed app at the socket level.
  Re-check `/v1/health` on both devices before believing any result.
- This rules out driving anything that requires the app to be backgrounded. The
  background-behaviour steps stay manual, and #205 cannot be driven at all — the
  condition under test is the one that kills the driver.

**The app now holds the screen awake for you.** `TestControlSession` acquires the
screen wake lock while the switch is on and releases it when it goes off, so no
Auto-Lock fiddling is needed. A build that has been explicitly handed to another
machine has no reason to sleep.

This was added after four failed attempts at a two-phone run. Each phone
suspended in turn while the other was being prepared, so there was never a moment
with two live surfaces. The active-ride wake lock (#50) cannot cover it: that one
holds the screen *during a ride*, but the driver needs both phones reachable
**before** the ride exists, in order to create and join it — and that pre-ride
window is exactly when an idle phone locks.

**The idle clock no longer counts suspended time.** It used to, and that was the
second half of the same failure. Copying the access token means leaving the app,
which backgrounds and suspends it; wall-clock time then ran against a 30-minute
timeout the operator had no way to refresh, and the first real request tripped the
expiry and switched the surface off. From outside, a silently-disabled toggle was
indistinguishable from a crashed app.

`TestControlController.touch()` restarts the clock on a foreground resume, so only
time the app could actually have served a request counts against it. The timeout
still does its job — a phone left on a bench with the app open closes its own port
— without punishing the person setting up. `/v1/health` deliberately does **not**
refresh it: liveness is unauthenticated, and letting an unauthenticated caller
hold a session open indefinitely would defeat the protection.

Both are regression-tested in `test_control_session_test.dart`.

## Failures are reported, never answered 200

`RideController` does not throw. `_run` catches everything into `errorMessage`,
and when an action is already in flight it returns having done **nothing**. So
`await` completing proves nothing about whether anything happened.

This was found by driving a live ride, not by reasoning. The local rider was Tail
End Charlie rather than the leader, so `POST /v1/ride/end` threw
"Only the ride leader can end the ride" internally — and the surface answered
**200**. The following `POST /v1/ride` then no-opped and answered 200 with the
*old* ride. A driven field test would have recorded a clean create-join-start
against a ride that never changed, and the numbers underneath it would have been
fiction.

The surface now clears the controller error before each mutation and reports any
error afterwards as `action_failed` — `400` when the controller marks it
non-retryable (which is also how it expresses "you are not the leader"), `409`
when retryable. The response still carries the post-action `state`, because a
driver deciding whether to abandon a run needs to know where the ride actually
got to. It also refuses outright when `RideController.busy` is set, rather than
letting `_run` silently drop the request.

Regression-tested in `test_control_server_enabled_test.dart`.

## What driving proves, and what it does not

The surface exercises the app's own code paths, so it is real evidence for
delivery, convergence, roster agreement and route logic.

It is **not** evidence for anything physical, and the same rule applies here as to
the Android emulator:

- **Radio.** Nothing here touches Nearby. Steps 1, 2, 7, 13 and 14 still need two
  physical phones.
- **Battery.** An automated run holds the app awake and busy. #269 is a
  four-hour screen-off measurement on real hardware.
- **Real GPS.** `/v1/location` injects a fix with whatever accuracy is asked for,
  so it cannot exercise the multipath and accuracy-rejection behaviour behind
  `maxAcceptedAccuracyMeters` - which is what #270 is about.

Label driven results as driven in
[field-test-results.md](field-test-results.md). A step passed under automation on
a simulator is not a step passed.

# Background location during a ride

A rider whose phone is in a pocket, in a tank bag, or showing another navigation
app has to keep contributing a position to the group. Until #205 the app could
not: `DeviceLocationSource` was foreground-only, so the group lost a
backgrounded rider entirely and their recorded trail became a straight line
between the last fix before the app was backgrounded and the first one after.

This is what is configured, why, and — importantly — what is **not yet
evidenced**.

## What runs, and when

Location runs **only between `DeviceLocationSource.start()` and `stop()`**, which
is the length of an active ride, or until the rider stops sharing. A started ride
that nobody ends does not keep sharing for ever: see
[When nobody ends the ride](#when-nobody-ends-the-ride). Outside that window the
app holds no location session at all. There is no always-on tracking, no
geofencing and no significant-location-change monitoring.

## iOS

Two halves, and they are a matched pair — either one alone does nothing:

| Where | What |
| --- | --- |
| `ios/Runner/Info.plist` | `UIBackgroundModes` → `location` |
| `device_location_source.dart` | `AppleSettings(allowBackgroundLocationUpdates: true, pauseLocationUpdatesAutomatically: false, showBackgroundLocationIndicator: true, activityType: ActivityType.otherNavigation)` |
| `BackgroundLocationPermissionBridge.swift` | Explicitly requests the While Using → Always promotion when the rider starts sharing |

Three deliberate choices:

- **`pauseLocationUpdatesAutomatically: false`.** Core Location otherwise decides
  the rider has stopped moving and powers the receiver down. On a ride a stop is
  a coffee stop, and the group still wants to know where that rider is.
- **`showBackgroundLocationIndicator: true`.** The blue pill is not a cost to be
  avoided. It is the honest signal that this app is using location right now.
- **Always for a running ride.** The initial system request grants While Using.
  At the same explicit Start/Enable action the native bridge requests the iOS
  promotion to Always. Physical build 33 showed that relying on While Using plus
  the indicator did not reliably survive Scenic taking the foreground.
- **Honest fallback.** If iOS still reports While Using, sharing starts while the
  app is visible but the ride UI says background GPS is limited and directs the
  rider to Settings. It does not describe that state as background-capable.

`NSLocationWhenInUseUsageDescription` now says that a ride keeps recording while
another app is in front or the screen is off, and that it stops when the ride
ends. The previous wording promised the opposite ("while the ride screen is
open"), which was accurate before this change and would have been a lie after it.

`NSLocationAlwaysAndWhenInUseUsageDescription` explains the active-ride use for
the second permission step. The app still holds no location session outside an
active ride.

## Android

Background location comes from a **location-typed foreground service**, not from
`ACCESS_BACKGROUND_LOCATION`.

| Where | What |
| --- | --- |
| `AndroidManifest.xml` | `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION` |
| `geolocator_android` (already) | `GeolocatorLocationService` with `android:foregroundServiceType="location"` |
| `device_location_source.dart` | `AndroidSettings(foregroundNotificationConfig: …)` |

`ACCESS_BACKGROUND_LOCATION` is **deliberately absent**. A location-typed
foreground service grants location while the app is backgrounded, so the extra
permission — and its separate, alarming system prompt — would buy nothing. Do not
add it without a concrete capability that needs it.

The notification is `setOngoing: true` and says what is happening and that it
stops when the ride ends or when the rider stops sharing. It is the rider's off
switch: it points at the app they end the ride from.

## When nobody ends the ride

A started ride used to share the rider's position until the app was killed. The
live presence channel, the journal's location events and the background stream
all run for as long as the ride is neither ended nor left, and nothing in the app
ended a ride on its own: the leader's completion suggestion (#244) needs a route,
90% progress and every rider at the destination, followers are never asked, and
the 24-hour timer only starts after an end. One group's leader was still visible
on the road, and later at an airport, seven hours after the group got home (#859).

A phone now notices when the ride has finished with its rider, asks, and stops
sharing if nobody answers. It never does that to a rider who is actually out
riding. The judgement is `assessDispersal` (pure), the timing is
`LocationSharingGuard`, and `LocationSharingCoordinator` wires them to the ride.
Every threshold is in `SharingDispersalPolicy` with the reason for it.

### What counts as still riding

Checked in this order; the first that applies wins, and a rider is only
*dispersed* when every one fails:

| Check | Meaning | Number |
| --- | --- | --- |
| Solo ride | No group to leave, so nothing to stop | - |
| Cannot tell | No fix of its own, or this phone cannot currently see the group | - |
| With the group | Another rider still in the ride within 2 km, last seen under two hours ago. A quiet phone is not a departed one: fixes follow distance travelled, so a group at a long lunch can go quiet on each other's screens | 2 km, 2 h |
| Group out riding | Another rider moving (2 m/s or more), heard from in the last minute, within 25 km. A rider who has fallen behind, or broken down, is not dispersed while the group rides | 25 km |
| Group paused | The leader paused the group (the existing `ridePaused` event, with its time from `ridePausedAt`): the group is stopped on purpose, and riders scatter around a stop. A pause nobody resumed is a ride nobody ended, so it is bounded | 2 h |
| On the route | Within 150 m of an unfinished route (under 90% ridden, the completion detector's own figure), unless parked on it for three hours | 150 m, 90%, 3 h |
| Marker waiting | A marker holding for a Tail End Charlie who has not yet passed, up to a ceiling | 90 min |

### The sequence

1. Dispersed, continuously, for **30 minutes**: the rider is asked "Still riding
   with <ride name>?" in a bar at the foot of the ride screen (never a dialog: it
   must not cover the map), and in a notification when the app is in the
   background.
2. If the group comes back, the rider rejoins the route, or the phone can no
   longer tell, the question goes away and the 30 minutes start again.
3. **Keep sharing** holds the question off for two hours.
4. **Stop sharing**, or no answer, pauses sharing. The countdown is **15 minutes
   from the later of the question and the last time the rider moved**: a rider on
   the road is asked but never stopped, and an unanswered question is not a
   refusal. A gap of more than five minutes between evaluations (the app was
   suspended) restarts the 30 minutes and gives a standing question a fresh
   window.

That is 45 minutes from the group dispersing to the last position leaving the
phone, for a rider who is parked.

### What pausing does

- The presence controller clears this rider's position from the relay and from
  Nearby and **refuses** any further one, so a late fix cannot undo the pause. The
  ride shell returns before the journal as well, so no location event is written.
  Sharing and recording pause together, because the ride journal is both.
- The location stream is stopped, which removes the iOS blue indicator and the
  Android foreground notification, **unless a watcher link is active**: that is a
  separate, explicit, time-boxed share with its own expiry and it needs the same
  stream.
- The ride is not ended and the rider has not left. The rider is still in the
  roster, shown by their last known position going stale, and still sees everyone
  else.
- An alert (SOS, a breakdown, "need help") switches sharing back on: a rider who
  raises an alert wants to be found.
- Resuming starts the stream first and only then lets positions out. If the stream
  cannot start, the rider stays paused and is told, rather than being shown
  "sharing" while nothing is flowing.

### How a rider can always tell

- A small dot on the ride menu button and on the Ride tab: green while sharing,
  amber while a question is up, grey when sharing is off. It has a spoken label.
- The ride menu says in words whether the group can see the rider, and is the way
  to stop or resume.
- The Ride tab has a card that says the same, with the same action.
- When a question is up, or sharing is off, a bar sits at the foot of the screen
  with the answer. It stays until sharing is back on.
- The platform's own indicator: the iOS blue pill and the Android foreground
  notification, which appear only while the stream is running.

### The notification

A local notification, shown only while the app is in the background and once per
question. Posting it is native (`AppDelegate.swift`, `SharingReminderChannel.kt`)
and decides nothing; Dart decides whether to. It needs the notification
permission that the push flow asks for at the start of a group ride, in builds
with push configured. Without it nothing is shown, and the question is still in
the app, so **the countdown never waits for a notification to be read**. iOS
keeps it off the screen while the app is open (`willPresent`). The Android
channel is `location_sharing_reminders`.

### Evidence still needed

None of this has been run on a real phone. Before #859 is closed, on both
platforms:

1. A group ride left running after everyone has gone home: the rider is asked
   about 30 minutes after they were last with anyone, the notification arrives
   with the app backgrounded and the phone locked, and sharing stops 15 minutes
   later. The platform indicator goes out with it.
2. A real ride is never asked: a stop at a cafe, a long lunch where the group goes
   quiet, a marker waiting at a junction, a Tail End Charlie several kilometres
   behind, a rider with the phone in a tank bag for the whole ride.
3. A rider asked while moving is not stopped until they have been parked for 15
   minutes.
4. Resume after a stop brings the position back on the other phone within a
   fix or two, and a rider who raises an alert while paused is visible.
5. The notification permission denied: the question and the stop still work.
6. An app restart while paused shows the recovered-ride choice as before; rejoining
   starts sharing again, because the rider chose to.

## Store review

Both stores treat background location as a declared capability, and both want a
justification in the reviewer notes rather than an inference from the code.

- **App Store.** Expect a question about `UIBackgroundModes: location`. The answer
  is the product: a group-riding app where the back marker has to be visible to
  the leader while the rider navigates in another app. Point at the explicit
  active-ride consent, Always promotion, visible blue indicator, and automatic
  stop at ride end.
- **Play Console.** The location declaration form asks whether the app accesses
  location in the background and why. The answer is the same, plus: the app uses
  a foreground service with a persistent notification, and does **not** request
  `ACCESS_BACKGROUND_LOCATION`.

Neither of these is done. They are release work, not code work.

## Not yet evidenced

Per the rule in [AGENTS.md](../AGENTS.md), background support is **not claimed**
until physical-device evidence exists. The configuration above is implemented
and unit-tested; the new Always-promotion path has not been run on a real phone.

What has to be recorded before #205 is closed, on **both** platforms:

1. A ride recorded with the app backgrounded for at least 20 minutes, with
   another navigation app in front, producing a **continuous trail** and a
   distance within a few percent of the bike's odometer.
2. A second device in the same ride seeing the backgrounded rider's position
   move, and the TEC gap tracking it.
3. The trail surviving a screen lock and an incoming phone call.
4. iOS: the blue background indicator visible for the length of the ride, and
   gone within a few seconds of the ride ending.
5. Android: the ongoing notification present for the length of the ride, gone
   when it ends, and the ride still recording after the app is swiped away from
   Recents (or a documented statement that it is not, if that is what happens).
6. A battery figure for a two-hour ride on each platform, so the cost is a known
   number rather than a worry.

Until 1–6 exist, the honest description of this work is "configured, unverified".

## Related

- #50 keeps the *display* awake. Different mechanism, and it does not keep
  location running.
- #166 proposes distance-based reporting with a separate keep-alive. It assumes
  fixes keep arriving; this is why they now do.
- `PositionReportPolicy` decides which delivered fixes become durable position
  reports (20 m). The platform filter here is 10 m and has to stay the smaller of
  the two — see the comment on `platformDistanceFilterMeters`.

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
is the length of an active ride. Outside that window the app holds no location
session at all. There is no always-on tracking, no geofencing and no
significant-location-change monitoring.

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
stops when the ride ends. It is the rider's off switch: it points at the app they
end the ride from.

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

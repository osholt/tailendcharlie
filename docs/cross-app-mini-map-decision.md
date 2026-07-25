# Cross-app group mini-map companion - platform decision record

Tracks issue #7: can a rider keep a small, glanceable group-position/ride-status
view visible while another navigation app (Google Maps, Waze, a connected
device's own app) is in the foreground?

## iOS: not viable, do not pursue

Apple's Picture in Picture API (`AVPictureInPictureController`) is scoped to
actual video/video-call content - it requires an `AVPlayerLayer` or a capture
preview layer behind it. There is no supported way to place an arbitrary
interactive view (a live Flutter map) into a PiP window. Doing so would mean
either disguising the map as video, which the issue explicitly rules out, or
reaching for an undocumented API, which risks App Store rejection and breaks
with the public-API-only approach already used elsewhere in this app (the GPX
Open-In work uses only public UTI/document-type declarations; the iOS Nearby
transport uses only documented Nearby Connections APIs).

Supported alternatives, per the issue's own suggestion:

- **Already built and sufficient today**: the in-app mini-map. This session
  fixed it to render real map tiles in portrait as well as landscape, so it is
  now a fully working, immediate answer for "check group status without
  leaving the ride screen" - it just requires switching back to Tail End
  Charlie rather than floating over another app.
- **A genuinely different, separately-scoped idea**: iOS Live Activities
  (Lock Screen / Dynamic Island) could show a compact status card - e.g. rider
  count, distance to next turn, TEC's separation - without rendering a live
  map at all. This is smaller and structurally distinct from "a floating map
  over another app" and deserves its own issue rather than folding into #7's
  PiP question.

## Android: policy-compliant prototype implemented

Android's `Activity.enterPictureInPictureMode()` is not video-restricted the
way iOS's API is, so a small, non-interactive PiP window showing rider dots,
route, and an alert badge is plausible without a private API or misleading
media trick.

The prototype now implements that design:

- **Rendering approach.** `GroupPipActivity` is a private, excluded-from-recents
  Android Activity backed by one lightweight native `Canvas` view. It draws
  bounded route polylines, rider/hazard dots, a short group/TEC status, and an
  alert badge. It does not host a second Flutter engine, fetch map tiles,
  request overlay permission, or disguise the content as video.
- **Data delivery.** `GroupPipSnapshot` is the small serializable boundary
  between the existing map state and native Android. The Dart side caps route
  geometry at approximately 500 points and markers at 100; native code checks
  coordinates and independently applies its own bounds. Nothing is published
  until the rider explicitly selects **Show mini-map over another app** and
  confirms the explanation.
- **Lifecycle and battery impact.** The issue requires real-device evidence
  for foreground/background transitions and battery cost. Automated Dart
  tests and a compiled APK cover the data contract and integration, but cannot
  provide that field evidence.

### Android 14 emulator evidence

The debug APK was exercised on a clean Android 14 Google Play ARM64 emulator
on 2026-07-25:

- a leader created an empty ride, explicitly selected the demo route, reviewed
  it, and opted in through **Show mini-map over another app**;
- Android entered native Picture-in-Picture and rendered the route-only
  snapshot without map tiles or overlay permission;
- the PiP remained visible when Google Maps became the foreground activity;
- the `GroupPipActivity` remained present across a screen-off/screen-on cycle
  and restored above Google Maps after unlock; and
- the PiP remained present while airplane mode was enabled, then disabled.

This validates the supported host lifecycle and offline-retention paths in the
official emulator. It does not substitute for the issue's physical-device
battery, external-navigation, lock/background, and live rider-update matrix.

**Recommendation**: retain the Android prototype as the supported cross-app
companion, subject to physical-device lifecycle and battery validation. Keep
iOS on the in-app mini-map; a separate Live Activity issue would be the
supported route to glanceable, non-map status outside the iOS app.

## What this record does and does not settle

The iOS platform decision is final because the public API surface itself rules
out a live arbitrary-map PiP window. The Android implementation is complete at
prototype level, but issue #7 must remain open until its required physical
foreground/background and battery evidence has been recorded.

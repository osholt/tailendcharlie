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

## Android: policy-compliant in principle, but unproven - needs a prototype before committing further

Android's `Activity.enterPictureInPictureMode()` is not video-restricted the
way iOS's API is, so a small, non-interactive PiP window showing rider dots,
route, and an alert badge is plausible without a private API or misleading
media trick.

What is **not** yet known, and can only be resolved by building a real
(throwaway) prototype rather than more reading:

- **Rendering approach.** The whole app is Flutter; a PiP window is a
  separate, small (roughly 200x150dp), non-interactive Activity. Hosting a
  full Flutter engine in that space is heavier than the content justifies.
  The mini-map's own non-tiled fallback path (`_GroupMiniMapPainter` in
  `ride_map_feature.dart`) already draws nothing more than circles and lines
  for exactly this kind of compact view - a good sign that a lightweight
  native Android `Canvas`/`View` doing the same simple drawing is a more
  realistic PiP renderer than embedding Flutter, but this needs to actually be
  tried, not assumed.
- **Data delivery.** There is no single "current ride status" snapshot today.
  Rider positions, hazards, route alerts, and leader/TEC separation are
  computed by three different owners - `SituationalAwarenessController`,
  `LeaderRideStatusCalculator`, and `active_ride_shell.dart`'s own
  aggregation - and only briefly unified inside that shell's private state.
  A PiP prototype needs a small, purpose-built, serializable snapshot type
  (rider positions/colours + an alert flag) pushed to native code. The
  existing `me.osholt.ride_relay/nearby_events` EventChannel (and the
  `gpx_import` MethodChannel added this session) are the right pattern to
  copy for that delivery - this part is moderate, well-understood Dart work,
  not a new architecture.
- **Lifecycle and battery impact.** The issue requires real-device evidence
  for foreground/background transitions and battery cost. That can only come
  from an actual running PiP Activity, not from documentation.

**Recommendation**: this is a legitimate, scoped follow-up - roughly a
throwaway Activity plus a minimal Canvas renderer fed by a synthetic snapshot,
to answer the rendering-approach question before investing in the real
snapshot pipeline. It should be its own piece of work, not something started
opportunistically alongside other changes.

## What this record does and does not settle

The issue's acceptance criteria calls for a decision record written *after*
native prototypes on both platforms. This document covers the platform-policy
half - what each OS actually allows, and what's structurally required - based
on documented API constraints and this app's current architecture. It does
not replace an Android prototype; it identifies exactly what that prototype
needs to answer. iOS needs no prototype, since the API surface itself rules
out a live-map PiP window regardless of implementation effort.

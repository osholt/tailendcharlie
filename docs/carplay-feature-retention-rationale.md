# CarPlay feature-retention rationale

Updated: 2026-09-03

## Decision

Tail End Charlie keeps every ride capability that can be expressed with the
public CarPlay navigation APIs. Guidance that merely recommends a simpler
experience is not being treated as a feature-removal requirement.

One visual implementation cannot return: the old framed inset minimap. Apple
requires a navigation app's root controller to draw only map content, says not
to render overlays or other UI there, and requires all UI overlays to use
CarPlay templates. The retired inset was a separate `UIView` with a border,
caption and snapshot image over the full-screen map. It was therefore an
additional app-drawn UI overlay, irrespective of the fact that its image showed
a map.

The capability is retained as **Group overview**. A CarPlay-owned button fits
all valid rider markers into the one full-screen map with margin. The overview
stays in place until the rider uses the always-present Recenter button. The same
action is also the first group row in the Ride list.

Authoritative Apple sources:

- [Displaying Content in CarPlay](https://developer.apple.com/documentation/carplay/displaying-content-in-carplay)
  requires the root view controller to draw only map content and says not to
  render alerts, overlays or other UI elements there.
- [Integrating CarPlay with Your Navigation App](https://developer.apple.com/documentation/carplay/integrating-carplay-with-your-navigation-app)
  requires `CPMapTemplate` as the root, a full-screen map, and CarPlay-provided
  templates for overlays.
- [`CPManeuver`](https://developer.apple.com/documentation/carplay/cpmaneuver)
  is the supported carrier for turn text, symbols and estimates; CarPlay chooses
  the longest supplied variant that fits the vehicle screen.
- [`CPMapTemplate`](https://developer.apple.com/documentation/carplay/cpmaptemplate)
  supplies the system map controls, trip previews, estimates and navigation
  alerts over the app's map.

## Retention matrix

| Previous element | Current implementation | Why this is retained/compliant |
|---|---|---|
| Full map, route ahead and rider identities | MapLibre content in the single full-screen root map | These are cartographic map content, not controls or panels. |
| Group minimap | **Group overview** fits all riders on the full map; Recenter returns to guidance | Preserves the group-wide spatial check without a prohibited second framed view. |
| Turn card and following turn | `CPNavigationSession` with current and following `CPManeuver`; full “Now” and “Then” text is also in Ride | Apple owns the driving card, Dashboard and notification presentation. No instruction data is discarded if a compact host shortens the card. |
| Journey ETA, remaining distance and next-stop ETA | `CPTravelEstimates` on the map plus Journey and next-stop rows in Ride | Uses CarPlay's required glanceable estimate surface while retaining the richer route detail. |
| Persistent TEC state | The first CarPlay navigation-bar button carries the current TEC headline and opens Ride for the full detail | System-owned button, so the safety state remains glanceable without an app-drawn badge. |
| Group count and GPS speed | The second system navigation-bar button shows rider count and current/mapped-limit values, and opens Group overview | Restores glanceable values in CarPlay-owned chrome. The full labelled speed/limit explanation remains in Ride. |
| Compass and map browsing | A compass-labelled `CPMapButton` opens CarPlay's panning interface; CarPlay gestures and map orientation remain active | Uses a public map operation instead of an app-drawn compass badge. |
| Zoom and Follow | System `CPMapButton` controls | Same capabilities and system-sized touch targets. |
| Alert, SOS, report and leave | Navigation-bar buttons, action/alert templates and a Ride-list action | All actions remain; destructive actions keep confirmations. |
| Clock | CarPlay's persistent system clock | The information is always present, so drawing a second clock would add no capability and would violate the root-view rule. |
| Marker and TEC warnings | Ride rows and time-bounded `CPNavigationAlert` for active safety events | Keeps the information without disguising group events as road manoeuvres. |
| Route planning and route preview | Search, `CPTrip` choices and Apple's trip-preview UI | Keeps route selection and makes the explicit Go decision host-owned. |
| Free roam and ride recording | System action starts free roam; navigation cancellation remains separate from ride lifecycle | Projection changes do not end or suppress ride recording. |

## Interpretation rule

Future reviews must distinguish an Apple prohibition (for example, app-drawn
UI over the root map) from design advice (for example, preferring less
secondary information). Advice can change hierarchy or wording, but does not by
itself authorize deleting a Tail End Charlie capability.

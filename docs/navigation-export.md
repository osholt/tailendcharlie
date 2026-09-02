# Navigation and ride-summary export

The active route map exposes one `Navigate or export route` action. Tail End Charlie
uses a documented universal link where a target supports one and otherwise
shares a standards-based GPX 1.1 file through the native share sheet.

The mobile code keeps these choices in one `navigationHandoffCapabilities`
registry. Each entry declares whether it uses a documented direct link or a
GPX share, how much route data Tail End Charlie can send, the supported mobile
platforms, and the rider-facing limitation. The registry can be filtered by
Android or iOS instead of assuming every future provider works identically on
both. Adding a provider requires a documented integration and a physical-device
test; Tail End Charlie does not invent private URL schemes. All current entries still
require the physical-device evidence tracked in issue #5.

The map also has an `Enter destination` action. It builds and saves a
road-following route from the current location, then optionally continues
straight into the Google Maps handoff or the Calimoto/MyRoute-app GPX share
flow selected by the rider.

## Target behavior

| Target | Tail End Charlie behavior | Limitation |
|---|---|---|
| Google Maps | Opens the documented HTTPS Maps URL with start, finish and at most three sampled via points | Google recalculates the route. It is a preview/handoff, not the original GPX geometry. Mobile support is limited to three waypoints. |
| Waze | Opens the documented HTTPS Waze deep link with motorcycle vehicle type | Waze accepts the final destination, not a complete GPX route. |
| Calimoto | Shares the generated GPX file | The rider must choose Calimoto in the native share sheet. Tail End Charlie does not use an undocumented app scheme. |
| MyRoute-app | Shares the generated GPX file | The rider must choose MyRoute-app in the native share sheet. |
| Garmin | Shares the generated GPX file | Choose a compatible installed app such as Garmin Drive, Tread or Explore. Device compatibility varies. |
| BMW Motorrad | Shares the generated GPX file | Choose BMW Motorrad Connected if installed; ConnectedRide device sync remains BMW-managed. |
| Generic GPX | Shares or saves the generated GPX file | The receiving app decides how to interpret tracks, routes and waypoints. |

If a Google Maps or Waze universal link cannot be opened, Tail End Charlie falls back
to GPX sharing so the route is not lost. A successful handoff still does not
prove that the receiving app preserved the intended road sequence. Riders must
check the calculated route before departure.

The GPX exporter writes GPX 1.1 tracks, route points, waypoints, elevation and
timestamps from the persisted active route. The native operating-system share
sheet controls which installed apps are offered; mobile apps cannot safely
preselect a third-party recipient.

## Projected navigation (CarPlay / Android Auto)

Apple approved Tail End Charlie's CarPlay Navigation entitlement under
Case-ID 21286533. The CarPlay scene therefore uses the navigation-only
window-bearing scene callback and a `CPMapTemplate` root. An app-owned MapLibre
canvas lets the head unit use the phone's resolved day/night style and
process-level tile cache. It draws the active route and current rider positions;
the local rider is followed until the map is panned.

The current active-ride implementation also draws guidance, ETA, group status,
speed and interactive ride controls directly in that base view. It cancels the
`CPNavigationSession` before the retained `CPManeuver` path can execute. This is
not the Apple-template navigation flow and is a compliance blocker recorded in
the [CarPlay navigation compliance checklist](./carplay-compliance-checklist.md).
A **Ride** button still opens a `CPListTemplate` with ride state, group/marker
status, alerts and a bounded rider list. Route setup and detailed settings stay
on the phone; an already configured leader can also receive a CarPlay **Start**
action.

Debug and Release signing request both
`com.apple.developer.carplay-driving-task` and
`com.apple.developer.carplay-maps`. The App ID and every provisioning profile
used for those builds must contain both restricted entitlements. Projected
state is refreshed at most once per second; the smaller camera viewport follows
the phone's 400 ms camera cadence independently. Route geometry is reduced to at
most 600 points before it crosses the platform channel.

Android Auto uses Android for Cars App Library 1.7.0 and declares the
navigation category. It renders the same bounded snapshot as a read-only
`ListTemplate`: route, next instruction, ride/group/marker state, priority
alert, and at most one rider needing attention. It does not persist rider
positions in the car integration. A cold host connection without an active
Flutter process shows `Open Tail End Charlie on the phone`; once the phone app
resumes, the existing journal-derived snapshot repopulates the car surface.

Debug builds accept the Desktop Head Unit host for development. Release builds
use the Car App Library's documented host allow-list and privileged template
renderer permission instead of trusting arbitrary callers.

### Driver-distraction and validation status

- Both projected surfaces keep route editing, ride creation/joining, roster
  management, and detailed settings on the phone. CarPlay additionally permits
  the leader to start an already-prepared ride and to confirm safety actions.
- Full projected state is refreshed no more frequently than once per second;
  the smaller camera viewport follows the phone's 400 ms cadence.
- Android Auto uses host-rendered templates rather than custom touch targets or
  a mirrored phone UI.
- Unit tests cover bounded snapshot parsing and in-process reconnect updates.
- Flutter analysis/tests, Android native unit tests, and a debug APK build cover
  compilation and phone-side state publication.
- Real-host or official Desktop Head Unit checks for disconnect/reconnect,
  no-signal, background recovery, day/night, and driving-state restrictions
  remain required before issue #6 can be closed or Android Auto can be described
  as field validated.

## Ride and marker summary

The active ride screen has a `Share ride summary` action. It shares a readable
summary and a CSV attachment containing:

- ride identifier, code and duration;
- local journal event count;
- each completed or currently active marker session;
- time spent marking; and
- unique passes observed during each marker session.

An active marker session is measured up to the export time and labelled active.
The summary is computed from the local durable event journal. It can therefore
be incomplete if another phone's events have not reached this device, or if the
ride is ended before the summary is shared. Share the summary before tapping
`End ride` in this development build.

## Source documentation

- [Google Maps URLs](https://developers.google.com/maps/documentation/urls/get-started)
- [Waze deep links](https://developers.google.com/waze/deeplinks)
- [Calimoto GPX import and export](https://support.calimoto.com/hc/en-us/articles/9036207495068-GPX-Import-Export)
- [MyRoute-app shared-route import](https://support.myrouteapp.com/en/support/solutions/articles/12000104345-traveling-with-mra)
- [Garmin Drive GPX sharing](https://support.garmin.com/en-US/?faq=dNtcaPyxXS1YoSGKzQIhGA)
- [Garmin Explore GPX import](https://support.garmin.com/en-ZA/?faq=JB2oAqEgCU17c7IqE3yHvA)
- [BMW ConnectedRide GPX support](https://support.bmw-motorrad.com/s/article/Use-ConnectedRide-Navigator-online-route-planning-K7U8R)

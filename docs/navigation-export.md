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

CarPlay has a Driving Task companion: a `CPListTemplate` showing each rider's
name, role, and off-route indicator, the current highest-priority alert, and an
SOS button wired to the same emergency alert as the phone's map. The app's
Debug and Release signing configurations request the approved
`com.apple.developer.carplay-driving-task` entitlement. The list is refreshed
at most once every ten seconds to remain a low-interaction, glanceable surface.

This is not a native map. `CPMapTemplate` and turn-by-turn guidance require
Apple's separate CarPlay Navigation entitlement; Driving Task approval does not
grant that capability. Tail End Charlie therefore keeps route planning,
maneuver guidance, ride setup, and detailed settings on the phone.

Android Auto is not implemented. It would use the Android for Cars App
Library and its own distraction-optimized templates, comparable in scope to
the CarPlay work above.

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

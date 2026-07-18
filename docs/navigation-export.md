# Navigation and ride-summary export

The active route map exposes one `Navigate or export route` action. Tail End Charlie
uses a documented universal link where a target supports one and otherwise
shares a standards-based GPX 1.1 file through the native share sheet.

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

## Planned projected navigation

Apple CarPlay and Android Auto companion surfaces are P1 roadmap features. The
intended scope is a low-interaction route view, next-action guidance, group
separation state, and urgent ride alerts backed by the phone's existing offline
ride journal. CarPlay requires the appropriate Apple entitlement and approved
template category; Android Auto must use the Android for Cars App Library and
comply with its distraction-optimized templates. Neither integration is
implemented or claimed by the current alpha.

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

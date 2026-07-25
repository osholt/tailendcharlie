# Live UK traffic incidents

Tail End Charlie can enrich a leader's active route with current UK closures,
works, collisions and significant road hazards from TomTom Orbis Traffic. The
integration keeps the TomTom API key on the relay server.

## Data path and privacy

1. The leader app splits the UK portion of the selected route into bounded
   viewports padded by the configured route corridor.
2. It asks the configured Tail End Charlie relay for current incidents in each
   viewport. The request contains no ride code, rider identity or GPS sample.
3. The relay validates UK-only bounds and a 9,500 km² safety limit, rounds bounds
   to a small shared cache grid, rate-limits callers and makes the authenticated
   provider request.
4. The app discards incidents whose geometry is more than 1 km from the route.
   Only those route-relevant results enter the signed ride journal, so followers
   receive the same source, freshness and expiry through the existing transports.
5. When the leader explicitly requests an alternative, the app sends the
   bounded remaining-route geometry (beginning at the current location when
   available), compact 150 m avoid rectangles around up to ten serious matched
   incidents, and opaque incident IDs to the relay. It
   does not send the ride code, rider identity or invite secret. The request is
   not stored by the relay.
6. The relay asks TomTom Orbis Routing for a live-traffic path alternative. It
   returns normalized route geometry, duration, traffic-delay comparison and
   guidance instructions. The leader sees the ordinary full-screen route
   review; only an explicit confirmation publishes one new authoritative route
   revision to riders.

The provider is TomTom's official
[Orbis Traffic Incident Details v2](https://developer.tomtom.com/traffic-api/documentation/tomtom-orbis-maps/v2/traffic-incidents/incident-details).
It exposes incident geometry, type, severity/delay, timing and report freshness.
Alternatives use the official
[Orbis Calculate Route v3](https://developer.tomtom.com/routing-api/documentation/tomtom-orbis-maps/v3/calculate-route)
service with live traffic, bounded avoid rectangles and guidance instructions.
Waze's public partner feed is not used as a read source.

## Configure

Create an approved TomTom application and put its server key only in the relay
environment:

```text
RIDE_RELAY_TOMTOM_TRAFFIC_API_KEY=...
```

Use a different key in isolated pre-production:

```text
PREPRODUCTION_RIDE_RELAY_TOMTOM_TRAFFIC_API_KEY=...
```

Never compile either value into Flutter or commit it. The relay reports an
explicit `traffic_provider_unconfigured` state when no key is present; rider
reports and all offline ride functions continue to work.

## Behaviour and limits

- Refresh is leader-only on route load and every five minutes.
- Results are labelled TomTom with last fetch time and provider expiry.
- A failed refresh leaves already journalled incidents visible until their
  stated expiry rather than replacing them with a false all-clear.
- The feature is limited to UK route geometry and never adds police-presence or
  speed-camera reports.
- Only serious and critical route-matched incidents offer a reroute.
- Dismissing or accepting an offer suppresses the same incident set until its
  provider expiry. A different incident set can offer a new review.
- If TomTom returns no path alternative, the current route is retained and the
  leader sees an explicit unavailable state.
- Alternative calculation uses the existing route-review boundary: no provider
  result can silently replace the leader's authoritative route.

Before enabling this in tester builds, confirm the selected TomTom plan and
contract permit the intended field-test volume and display/redistribution
behaviour. Record a staged closure test and a provider-failure test in
`docs/field-test-plan.md`.

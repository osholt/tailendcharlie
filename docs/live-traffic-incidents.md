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

## Licensing and enablement gate

TomTom documents detailed Traffic Incidents and Traffic Flow coverage for the
United Kingdom:

- [Traffic API market coverage](https://developer.tomtom.com/traffic-api/documentation/tomtom-maps/v1/product-information/market-coverage)
- [Published self-service pricing](https://developer.tomtom.com/pricing)

The published pricing currently lists 2,500 free non-tile requests per day,
then EUR 0.75 per 1,000 Traffic incident or Routing requests. However, the
current self-service
[TomTom Developer Portal terms](https://developer.tomtom.com/terms-and-conditions)
exclude use for "Navigation Functionality" unless TomTom permits it under a
separate written agreement. Tail End Charlie must therefore obtain and record
that written permission (including tester display, caching and redistribution
terms) before a provider key is configured or availability is claimed.

## Configure

After the written navigation permission and plan are approved, create the
TomTom application and put its server key only in the relay environment:

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

Before enabling this in tester builds, record the written navigation permission
and confirm the selected plan permits the intended field-test volume,
display/caching and redistribution behaviour. Record a staged closure test and
a provider-failure test in `docs/field-test-plan.md`.

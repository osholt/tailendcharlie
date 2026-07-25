# Live UK traffic incidents

Tail End Charlie can enrich a leader's active route with current UK closures,
works, collisions and significant road hazards. Two sources are supported: a
Waze for Cities partner feed and TomTom Orbis Traffic. The integration keeps
both credentials on the relay server; the app never talks to either provider.

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

## Providers

### Waze for Cities (preferred for incidents)

When a Waze for Cities feed URL is configured the relay reads incidents from
it and TomTom is not called for incidents. The feed is the partner
[Waze Data Feed](https://support.google.com/waze/partners/answer/13458165)
of `alerts` and `jams`. It is a whole-area snapshot rather than a bounded
query, so the relay fetches it once per cache window and serves each viewport
by filtering that snapshot; the app's request contents and privacy properties
are unchanged.

Normalisation rules, all enforced on the relay:

- Alert types are an **allowlist**: `ACCIDENT`, `ROAD_CLOSED`, `CONSTRUCTION`,
  `HAZARD`, `WEATHERHAZARD` and `POLICE`. A category Waze adds later is
  dropped rather than shown as an unclassified hazard.
- Enforcement is first-class. `POLICE` maps to `policeActivity`, and any
  subtype containing `CAMERA`, `RADAR` or `SPEED_TRAP` maps to `speedCamera` —
  including the documented `HAZARD_ON_ROAD_MOBILE_SPEED_CAMERA`. Both are
  `serious`, both are exempt from the confidence floor below, and both drive
  the advance warning described in
  [situational-awareness.md](situational-awareness.md).
- Crowd reports below Waze reliability 5 are discarded, **except** enforcement
  reports. A low-confidence pothole is noise; a low-confidence camera warning
  is still worth having, and missing one costs the rider more than a false
  positive does.
- Jams below level 3 are ignored. Level 4 and above, or a delay of ten minutes
  or more, is `serious` and therefore eligible for a reroute offer; level 3 is
  `caution` context only.
- The feed carries no per-incident expiry, so each reading expires ten minutes
  after the fetch that produced it.
- Waze publishes no routing API. Alternatives always come from TomTom, and
  when only Waze is configured the reroute endpoint reports
  `traffic_provider_unconfigured` rather than pretending to be available.

If the Waze feed fails and TomTom is also configured, the relay falls back to
TomTom for that request. With no fallback configured the Waze failure is
surfaced as-is; incidents already in the journal remain until their expiry.

### TomTom Orbis

TomTom's official
[Orbis Traffic Incident Details v2](https://developer.tomtom.com/traffic-api/documentation/tomtom-orbis-maps/v2/traffic-incidents/incident-details)
exposes incident geometry, type, severity/delay, timing and report freshness.
Alternatives use the official
[Orbis Calculate Route v3](https://developer.tomtom.com/routing-api/documentation/tomtom-orbis-maps/v3/calculate-route)
service with live traffic, bounded avoid rectangles and guidance instructions.

## Licensing and enablement gate

### Waze for Cities

Waze for Cities Data is a partnership, not a self-service API. Before a feed
URL is configured, record the signed partner agreement and confirm in writing
what it permits for this app: display to riders in a consumer motorcycle app,
the caching described above, redistribution to ride followers through the
signed journal, and the required "Powered by Waze" style attribution. The app
labels every reading with its source, but attribution wording is a contractual
question that the agreement must settle. Do not configure the feed URL, or
claim Waze support anywhere, until that is recorded.

### TomTom

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

After the written permission and plan for a given provider are approved, put
its credential only in the relay environment:

```text
RIDE_RELAY_TOMTOM_TRAFFIC_API_KEY=...
RIDE_RELAY_WAZE_TRAFFIC_FEED_URL=https://www.waze.com/row-partnerhub-api/partners/<id>/waze-feeds/<token>
```

Use different values in isolated pre-production:

```text
PREPRODUCTION_RIDE_RELAY_TOMTOM_TRAFFIC_API_KEY=...
PREPRODUCTION_RIDE_RELAY_WAZE_TRAFFIC_FEED_URL=...
```

The Waze feed URL embeds the partner token, so it is handled as a secret: it
is validated as an `https` `waze.com` URL, never logged, and never returned to
a client. `RIDE_RELAY_WAZE_TRAFFIC_FEED_CACHE_SECONDS` (default 120, minimum
60) bounds how often the relay polls it; keep it at or above the refresh
interval the partner agreement specifies.

Never compile either value into Flutter or commit it. The relay reports an
explicit `traffic_provider_unconfigured` state when no credential is present;
rider reports and all offline ride functions continue to work. Either provider
can be configured alone: with only Waze, incidents work and rerouting reports
itself unconfigured.

## Behaviour and limits

- Refresh is leader-only on route load and every five minutes.
- Results are labelled with their own source (TomTom or Waze), last fetch time
  and provider expiry. An unrecognised source is rejected rather than shown
  without attribution.
- A failed refresh leaves already journalled incidents visible until their
  stated expiry rather than replacing them with a false all-clear.
- The feature is limited to UK route geometry.
- Only serious and critical route-matched incidents offer a reroute, and
  enforcement types are excluded from that set regardless of severity. A
  camera is warned about, never routed around: it is not an obstruction, and
  the group's authoritative route is not the place to react to one.
- Dismissing or accepting an offer suppresses the same incident set until its
  provider expiry. A different incident set can offer a new review.
- If the routing provider returns no path alternative, the current route is
  retained and the leader sees an explicit unavailable state.
- Alternative calculation uses the existing route-review boundary: no provider
  result can silently replace the leader's authoritative route.

Before enabling this in tester builds, record the written navigation permission
and confirm the selected plan permits the intended field-test volume,
display/caching and redistribution behaviour. Record a staged closure test and
a provider-failure test in `docs/field-test-plan.md`.

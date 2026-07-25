# Crowd hazard feed decision

Status: accepted research decision  
Date: 2026-07-23  
Issue: [#40](https://github.com/osholt/tailendcharlie/issues/40)

## Decision

Do not ingest, scrape, cache or describe Waze or Google Maps consumer reports as
available to Tail End Charlie. No documented public interface reviewed here
grants this app a feed of police presence, mobile cameras or Waze/Google
community observations.

Keep two separate product paths:

1. For closures, works, collisions and significant road hazards, continue #39
   with a licensed route-relative incident provider. Mapbox Directions
   `driving-traffic` is the clearest current technical candidate; TomTom Traffic
   is a second candidate subject to a commercial terms and redistribution
   review.
2. Retain the existing first-party, ride-scoped reporting feature for general
   road hazards, but remove police-presence, speed-camera and enforcement
   categories from new reports unless a documented data right and
   market-by-market legal approval are obtained.

The app must remain fully useful without either feed.

## Evidence

### Waze

- [Waze partner data feeds](https://developers.google.com/waze/data-feed/overview)
  describe data that partners provide **to Waze**. They are not a download API
  for Waze user observations.
- The [Waze Transport SDK](https://developers.google.com/waze/intro-transport)
  requires a partnership and explicitly does not provide server-side traffic
  reports or driver-speed data, an embedded Waze map, or a way to build a
  navigation product. Its permitted route/ETA use also requires nearby
  “Powered by Waze” attribution.
- The [Waze Live Map iframe](https://developers.google.com/waze/iframe) embeds
  Waze's own web map. It does not grant rights to extract and redraw reports on
  Tail End Charlie's map.

Conclusion: Waze is not a supported source for this feature. Existing deep-link
handoff remains the appropriate integration.

**Amended 2026-07-25.** The technical finding above holds for every interface
reachable without a partnership. It does not cover Waze for Cities Data, the
partner programme whose signed participants do receive a read feed of Waze
alerts and jams. Tail End Charlie is now expecting access to that feed, so a
relay-side reader for it is implemented in
[live-traffic-incidents.md](live-traffic-incidents.md) under path 1 above,
alongside TomTom rather than replacing it. No feed URL is configured and no
Waze support may be claimed until the partner agreement and its display,
caching, redistribution and attribution terms are recorded.

### Google Maps Platform

- The documented [Roads API](https://developers.google.com/maps/documentation/roads/overview)
  provides road matching and speed-limit metadata, not Google Maps community
  incident or police reports.
- The [speed-limit endpoint](https://developers.google.com/maps/documentation/roads/speed-limits)
  requires an Asset Tracking licence, returns the maximum automobile limit for
  variable-limit segments, and warns that values may be estimated, incomplete,
  outdated and non-real-time.
- Google's [EEA Roads API terms guidance](https://developers.google.com/maps/comms/eea/roads)
  says Roads API content cannot be visually associated with another map for EEA
  customers. That makes it unsuitable for the current third-party-map design
  without a different presentation and contract review.

Conclusion: Google exposes no documented crowd-report feed for #40. Roads API
speed-limit feasibility remains separate in #41.

### Licensed incident candidates for #39

- [Mapbox Directions](https://docs.mapbox.com/api/navigation/directions/) can
  return incidents on a `driving-traffic` route. Documented types include
  accidents, construction, disabled vehicles, lane restrictions, closures,
  road hazards and weather, with impact, time, affected geometry and closure
  state. The documented list does not include police or speed-camera reports.
  Traffic coverage is limited to Mapbox's supported geographies and must be
  checked for each launch market. The
  [current public pricing](https://www.mapbox.com/pricing) includes a
  request-based Directions API free tier and paid volume bands; both coverage
  and price remain launch-time checks rather than constants in application
  code.
- [TomTom Traffic incident tiles](https://developer.tomtom.com/traffic-api/documentation/tomtom-maps/v1/traffic-incidents/raster-incident-tiles)
  provide current incident severity/closure rendering. Before selection, the
  team must obtain written confirmation of the intended mobile display,
  attribution, cache duration, offline use and redistribution rights under the
  applicable TomTom plan. TomTom publishes
  [usage-based developer pricing](https://developer.tomtom.com/pricing), but
  the tile allowance does not by itself grant offline storage or redistribution
  rights.

Conclusion: these are candidates for safety incidents and rerouting, not a
lawful substitute for proprietary consumer enforcement reports.

## First-party ride/group reporting boundary

Permitted initial categories:

- obstruction or debris;
- oil, gravel or poor surface;
- stopped or disabled vehicle;
- collision;
- animals;
- weather or flooding;
- road closed or passability uncertain.

Excluded categories:

- police presence;
- mobile or fixed enforcement;
- speed cameras;
- attempts to identify enforcement personnel or vehicles.

Each report contains a category, point or short affected segment, direction,
reporting rider's ride-scoped identifier, observed time, expiry and optional
short constrained note. It contains no public account, free-form accusation,
photo, precise historical trail or invitation secret.

Suggested pre-release defaults to test (the development-alpha expiry policy is
currently broader and must not be presented as live-data freshness):

- 15-minute expiry for transient hazards;
- 60-minute expiry for closure/passability reports;
- merge reports of the same category, direction and location within 100 metres
  and 10 minutes;
- increase confidence with independent confirmations, but always show source,
  age and confidence;
- let riders dismiss a report locally and let the leader mark it resolved;
- never replace the authoritative route automatically.

Reporting controls must be usable only while stopped in the first release.
Display is glanceable and non-modal; creation, confirmation and dismissal must
not obscure SOS or navigation controls.

## Storage and moderation

- Do not put a provider's raw response into the ordinary ride event journal.
  Keep only the minimum normalised fields needed for the active route, and only
  for the cache period explicitly permitted by the provider contract.
- First-party reports may use signed ride events with an explicit expiry. The
  reducer ignores expired reports, and normal encrypted ride-retention cleanup
  removes their underlying events.
- Rate-limit reports per rider and category. Collapse duplicates before display.
- Preserve report, confirm, resolve and moderation actions as ride-scoped audit
  events; do not publish reporter identity outside the authenticated ride.
- A later public or cross-ride feed needs abuse reporting, trust scoring,
  moderation operations and a separate privacy/legal review. It is not part of
  this decision.

## Release gates

- Provider credentials and plan are held server-side; no billable secret ships
  in the mobile app.
- Written terms review records attribution, caching, offline use,
  redistribution, coverage and cost before provider data is enabled.
- Enforcement-related categories remain disabled in every market until local
  counsel approves the exact feature and copy.
- Tests use synthetic incidents unless the selected provider expressly permits
  recorded fixtures.
- Field testing covers false reports, duplicate merging, expiry, direction,
  stale/offline state and rider distraction.

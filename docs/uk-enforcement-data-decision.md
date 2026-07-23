# UK safety-camera and enforcement data

Status: provider selected; commercial access required
Date: 2026-07-23
Market: United Kingdom only
Related issue: [#40](https://github.com/osholt/tailendcharlie/issues/40)

## Decision

Pursue a commercial data agreement with
[Cyclops](https://cyclops-uk.com/cyclops-for-partners/) as the first choice for
UK fixed, average-speed, red-light, mobile-zone and current community-reported
camera information.

Cyclops is a materially better fit than attempting to read Waze or Google
consumer reports:

- it explicitly lists United Kingdom coverage;
- it supplies automotive, navigation, fleet and dash-cam partners;
- its database combines field verification with real-time reports from its own
  driver community; and
- its Live Alert Server supports partner-specific API delivery and corridor
  matching.

The integration remains disabled until Cyclops supplies an API specification,
test credentials and written terms covering mobile display, cache duration,
attribution, UK-only filtering and redistribution to Tail End Charlie users.
There is no public anonymous endpoint that can safely be embedded in tonight's
build.

## Alternatives

### Waze for Cities data feed

Google's
[Waze Data Feed](https://support.google.com/waze/partners/answer/10618035?hl=en)
is a near-real-time technical source: partner JSON or XML feeds are refreshed
about every two minutes and include traffic and hazard reports. The published
[alert schema](https://support.google.com/waze/partners/answer/13458165?hl=en)
includes a `HAZARD_ON_ROAD_MOBILE_SPEED_CAMERA` subtype, but does not document a
general police-location alert for partner feeds.

It is not a public Google API. Each feed URL contains a partner token and is
limited to an approved managed area under a Waze partner agreement. Google's
[eligibility rules](https://support.google.com/waze/partners/answer/10453062?hl=en)
currently restrict applications to government agencies and private road
operators. Tail End Charlie therefore cannot lawfully or reliably build its
consumer feature from this feed without a qualifying UK authority/operator
partner and explicit Waze approval covering in-app redistribution. If such a
partner sponsors access, Waze could augment live mobile-camera and road-hazard
coverage; it does not replace the commercial camera database decision today.

### TomTom

[TomTom Safety Locations](https://developer.tomtom.com/navigation/android/guides/virtual-horizon/horizon-safety-locations)
is the strongest technical alternative. It exposes fixed, mobile, red-light
and enforcement-zone data along the active navigation horizon, supports
country/region filtering, and explicitly makes the Safety Cameras entitlement
available on request through sales.

TomTom would couple the feature to its extended native Maps and Navigation SDK
on both mobile platforms. That is a larger navigation-platform change than a
provider-neutral server feed, so it is the second choice unless commercial
terms or the Cyclops API make Cyclops impractical.

TomTom's separate
[Connected Services API](https://developer.tomtom.com/connected-services-api/product-information/introduction)
is also access-controlled and provides low-latency traffic, road and weather
hazards. It is a useful candidate for issue #39, but is not a substitute for
the Safety Cameras entitlement.

### PocketGPSWorld / CamerAlert

[PocketGPSWorld](https://www.pocketgpsworld.com/copyright.php) offers a
commercial licence through `business-licence@pocketgpsworld.com`. Its public
member subscription expressly forbids business redistribution. The published
database is normally released weekly, so it is a useful UK fixed/mobile-site
fallback but does not meet the preferred real-time requirement by itself.

## Required provider questions

1. UK-only price at expected monthly active-rider and request volumes.
2. REST, streaming or downloadable formats and a sandbox/test feed.
3. Fixed-camera, average-zone, red-light, mobile-zone and live-mobile schemas.
4. Direction, bearing, enforced speed, confidence, observed time and expiry.
5. Allowed on-device cache duration and offline operation.
6. Required attribution and whether normalised route-relative results may be
   relayed from the Tail End Charlie server to authenticated ride members.
7. Service-level, update-frequency and correction/reporting guarantees.
8. Whether first-party Tail End Charlie rider confirmations may be returned to
   the provider.

## Product and architecture boundary

- Enable provider data only when the current route/position is in the UK.
- Keep credentials on the relay server; do not put billable partner secrets in
  the Flutter application.
- Request only a bounded corridor ahead of the current route.
- Normalise type, position/zone, direction, source, confidence, observed time
  and expiry; do not persist the raw provider payload in the ride journal.
- Show source and age, and distinguish a verified fixed site from a recently
  reported mobile location.
- Retain the last permitted cached snapshot when offline, visibly mark it
  stale, and never imply that an absent report proves there is no enforcement.
- Do not enable the feature when crossing outside the supported UK market.

## Tonight's release

The release may include this decision and provider-neutral boundaries, but it
must not display fabricated, scraped or unlicensed camera/police data. Existing
ride-scoped safety hazards continue to work without the provider. The feature
can be enabled in a later build without changing the event journal once
Cyclops or TomTom credentials and written rights are in place.

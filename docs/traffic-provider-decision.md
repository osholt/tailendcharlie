# Licensed live-traffic provider decision

Decision date: 3 August 2026  
Decision: **none for now**

The app does not enable a licensed live-traffic feed in closed-test or public
builds. Rider-created hazards remain available offline. The existing
provider-neutral incident, route-correlation and leader-approved reroute code
stays disabled unless a future written provider agreement and funded operating
plan pass the gates below.

This is a product/licensing decision, not a claim that the existing integration
failed technically.

## Candidate comparison

| | TomTom Traffic Incidents | HERE Traffic API v7 |
| --- | --- | --- |
| UK coverage | TomTom lists detailed Traffic Incidents and Traffic Flow coverage for the United Kingdom. Incident data is updated every minute. | HERE lists incident coverage for the UK including the Channel Islands and says incident data is updated every two minutes. |
| Useful response | Incident Detail returns real-time incidents suitable for route-corridor matching. The repository already has a bounded, server-held adapter and leader-only five-minute refresh. | The incidents endpoint supports a route corridor and returns type, severity, geometry/reference, source update, start/end time and descriptions. |
| Small-scale cost | The current self-service page includes 2,500 Traffic Incident Details calls per month free, then pay-as-you-grow tiers. A typical single-bounds two-hour ride at the app's five-minute refresh is about 25 calls, so the allowance is useful for evaluation but not a permanent operating guarantee. Long routes can require more than one bounds call per refresh. | HERE advertises a Base Plan with free monthly thresholds and transaction billing, but the public page does not expose a dependable traffic-unit price without account/plan context. It requires billing setup and directs excluded use cases to sales. |
| Caching and group redistribution | Results may be cached only where cache-control headers permit and not to scale one request to multiple users. The app's leader-fetches-once, signed-group redistribution therefore needs explicit written permission. | Caching follows response headers or a limited end-user-use exception; building a repository or scaling one request to multiple users is prohibited. Leader-to-group redistribution therefore needs explicit written permission. |
| In-vehicle/navigation fit | Portal terms exclude Automotive Usage and Navigation Functionality without a separate written agreement. They explicitly treat CarPlay as automotive screen-replication technology. | Base Plan restrictions exclude asset tracking/route/safety-alert use cases, while the general terms restrict vehicle-system displays and vehicle platooning unless the subscription permits them. This app needs a custom written agreement, especially for CarPlay and group coordination. |
| Attribution and end-user terms | TomTom attribution must remain visible; services without generated attribution use its Copyright API. | HERE copyright/source attribution and applicable end-user/supplier terms must be passed through. |

The material constraints are not the raw API call count. Both candidates cover
the UK and both can return usable incidents. The blockers are rights to show
provider results on the existing OpenFreeMap-based phone/CarPlay surface, relay
one leader fetch to a private group, retain a bounded offline snapshot and use
the result to offer navigation changes.

## Why none for now

- Tail End Charlie is currently a free, private-test product with no funded
  traffic-data budget or contract owner.
- TomTom's public allowance could cover modest testing, but its self-service
  terms do not grant this navigation/CarPlay and redistribution use.
- HERE's Base Plan expressly excludes use cases close to live group rider
  tracking and safety alerts, so “free tier” is not permission for this app.
- Enabling either key before written permission would turn a useful technical
  prototype into a licensing and availability liability.
- Rider reports already provide an honest, offline-first hazard path without
  implying a comprehensive live feed.

The current server adapter keeps credentials outside the repository and returns
an explicit unconfigured response when no key exists. The mobile UI says that
no provider is configured and that rider reports still work offline. It must
not say that the road is clear merely because no licensed result was fetched.

## Reconsideration gate

Reopen the choice only when there is an owner and budget. Before configuring a
tester or production key, obtain written confirmation covering:

1. phone navigation and CarPlay display;
2. overlay on the project's chosen non-provider basemap;
3. leader-only server fetching and redistribution to all ride members;
4. cache duration, offline display and signed-event retention;
5. attribution and enforceable end-user terms;
6. UK motorcycle/group-coordination use; and
7. request caps, overage controls, key separation and termination behavior.

Then run step 19 of the field-test plan in isolated pre-production before
changing the product decision. Until then, that step is deliberately deferred,
not failed and not a release gate.

## Primary references

- [TomTom Traffic API overview](https://docs.tomtom.com/traffic-api/documentation/tomtom-maps/v1/product-information/introduction)
- [TomTom Traffic API market coverage](https://docs.tomtom.com/traffic-api/documentation/tomtom-maps/v1/product-information/market-coverage)
- [TomTom pricing](https://docs.tomtom.com/pricing)
- [TomTom portal terms](https://developer.tomtom.com/terms-and-conditions)
- [HERE Traffic API v7 incidents](https://docs.here.com/traffic-api/reference/getincidents)
- [HERE Traffic coverage](https://docs.here.com/traffic-api/docs/traffic-vector-tile-traffic)
- [HERE Base Plan restrictions](https://www.here.com/get-started/pricing/base-plan-restrictions)
- [HERE developer terms](https://developers.here.com/terms-and-conditions)

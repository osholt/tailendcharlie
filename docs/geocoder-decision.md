# Destination search (geocoder) decision

Decision date: 12 August 2026
Decision: **stay on the public Nominatim instance, search on submit only**

The app keeps using `nominatim.openstreetmap.org` for destination search, and
results appear when the rider submits the field rather than as they type. No
geocoder is self-hosted and no commercial provider is engaged.

This is a terms-of-use decision, not a claim that as-you-type search is hard.

## What is actually wired today

Destination search is not new and was not added by #431. It has been in the app
since destination planning landed:

| Piece | Where |
| --- | --- |
| Endpoint | `RoutingConfiguration.geocodingBaseUrl`, defaulting to `https://nominatim.openstreetmap.org`, overridable with `--dart-define=RIDE_RELAY_GEOCODING_URL` |
| Client | `NominatimDestinationSearchService` — `/search?format=jsonv2&limit=5`, HTTPS enforced, in-memory cache keyed by query, raw `lat,lon` parsed without a network call |
| Planning | `DestinationRoutePlanner.planForReview` geocodes origin, stops and destination, then routes through them |
| Identification | A `User-Agent` naming the app and its repository, as Nominatim requires |

#431 recorded that "a destination search does not exist yet … that is the bulk
of this issue and it needs a provider decision". **That was wrong.** What did not
exist was a way to reach the search *before a ride existed*; the geocoder itself
was already there and already used from inside a ride. #466 connected it to the
home map and did not add a provider.

## Why not as-you-type

The Nominatim usage policy sets out limits for the public instance: roughly one
request per second maximum, a required identifying `User-Agent`, and — the
material point here — **auto-complete search must not be implemented against the
public API**. It is listed as an unacceptable use, not a rate to stay under.

A field that queries per keystroke would issue five to fifteen requests for one
destination. At that rate the app would be abusing a service donated by the
OpenStreetMap Foundation, and the likely outcome is a block that takes destination
search away from every rider, not a warning.

So the search submits. It costs one tap.

## What as-you-type would actually require

Not a decision about typing. A decision about running a geocoder.

| Option | Assessment |
| --- | --- |
| **Self-host Nominatim** | Wants tens of gigabytes for a Great Britain extract plus a PostgreSQL/PostGIS instance and periodic diff imports. The relay host is an Oracle Always Free VM with **954 MB of RAM and no swap until one was added specifically so `docker build` would not be killed**. This does not fit, and it is not close. |
| **Self-host Photon** | Lighter than Nominatim and designed for exactly this — typeahead over an OSM index. Still wants an Elasticsearch/OpenSearch process and a multi-gigabyte index. Also does not fit the current host. |
| **A commercial geocoder** | Fits technically and reintroduces the whole `traffic-provider-decision.md` problem: a contract owner, a funded budget, per-request billing, and terms that must permit a navigation product with a CarPlay surface. No such budget exists. |
| **A bigger relay host** | The honest prerequisite for either self-hosted option. It also ends the Always Free arrangement the deploy automation was built around. |

None of these is blocked by engineering. Each is blocked by money, a host, or a
contract, which is why this is a written decision rather than a task.

## Consequences accepted

- One extra tap to search. Stated in `home_destination_search.dart` and enforced
  by a test that fails if a keystroke ever triggers a search, so a future change
  cannot reintroduce autocomplete quietly.
- Five results per query, which is Nominatim's `limit` and is enough for a place
  name or postcode.
- No results while offline. Destination search is the one part of route planning
  that cannot work from the tile cache.
- Queries leave the phone. A typed destination goes to the OpenStreetMap
  Foundation's instance over HTTPS with no account and no identifier beyond the
  app's `User-Agent`. Worth knowing, and worth saying to a rider if the wording of
  the search surface is ever revisited.

## Reconsideration gate

Revisit when **all** of these hold:

1. A rider has said the submit tap is a real problem on the bike, rather than it
   being assumed to be one.
2. A relay host exists with the memory and disk for Photon plus its index, and
   somebody owns its cost.
3. The rate and caching behaviour of the chosen option has been written down
   here, the way this file writes down Nominatim's.

Until then the answer is submit-only search against the public instance, which is
within its terms and works.

## Primary references

- OSMF Nominatim Usage Policy — rate limit, `User-Agent` requirement, and
  autocomplete listed as an unacceptable use.
- Nominatim installation notes — hardware and import requirements for a
  self-hosted instance.
- Photon documentation — index and search-engine requirements.
- `docs/traffic-provider-decision.md` — the precedent for recording a
  provider decision here rather than assuming one.

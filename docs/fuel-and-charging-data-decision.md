# Fuel prices, fuel stations and chargers: data-source decision

Decision date: 10 October 2026. Tracked by #951.

The operator asked for petrol stations and chargers with prices on the map, a
search button that navigates to one based on the rider's fuel, and live prices
from the UK government's fuel price API. This document records where each kind
of data can come from and on what terms. It was written before any code.

## Decision

| Data | Source for build 103 | Why | What the rider sees |
| --- | --- | --- | --- |
| UK fuel prices | **Fuel Finder** (statutory, Motor Fuel Price (Open Data) Regulations 2025), fetched by the relay | The only complete, official, near-live UK source. The CMA interim feeds it replaced closed on 1 May 2026. | Price for the rider's fuel, labelled with the time it was confirmed. Prices appear only once the operator has registered (below). |
| UK fuel station locations | **OpenStreetMap `amenity=fuel`**, bundled offline layer | Works without signal, ODbL, no credentials. | Stations without signal, without prices. |
| Chargers | **OpenStreetMap `amenity=charging_station`**, same bundled layer | The statutory charger open data has no central endpoint: it is one feed per operator. | Charger locations and connector types. **No tariffs and no live availability** in build 103. |
| France fuel prices | **prix-carburants open data**, fetched by the relay, off until enabled | Open licence, no credentials, ten-minute feed. Simple next to Fuel Finder. | Price for the rider's fuel in France, once the operator enables it. |

Prices reach a phone only from the relay. Phones never call a government API.

## UK fuel prices: Fuel Finder

### Legal basis

- [The Motor Fuel Price (Open Data) Regulations 2025](https://www.legislation.gov.uk/uksi/2025/1356/contents)
  (SI 2025/1356). They extend to England and Wales, Scotland and Northern
  Ireland. Reporting and sharing (Parts 4 and 5) came into force on
  **2 February 2026**
  ([regulation 1](https://www.legislation.gov.uk/uksi/2025/1356/regulation/1/made)).
- A forecourt must report a price change to the aggregator **within 30 minutes**
  of the change
  ([regulation 9(2)](https://www.legislation.gov.uk/uksi/2025/1356/regulation/9/made)).
- The aggregator must keep prices "at all times" on a price API, updated within
  **5 minutes** of a report, and publish a flat file twice a day. It may set
  standards for how recipients use the data and withhold data from a recipient
  that does not meet them
  ([regulation 13](https://www.legislation.gov.uk/uksi/2025/1356/regulation/13/made)).
- An information recipient is anyone who registers with the aggregator for
  access ([regulation 12](https://www.legislation.gov.uk/uksi/2025/1356/regulation/12/made)).

The consequence that matters for the app: **a UK price is current until the
forecourt reports a change**, and the forecourt is legally bound to report it
within 30 minutes. A price set three weeks ago and still listed is a current
price, not a stale one. What can go stale is *our copy*: the relay's last
successful check, and the phone's last download.

### Access

From GOV.UK, [Access the latest fuel prices and forecourt data via API or email](https://www.gov.uk/guidance/access-the-latest-fuel-prices-and-forecourt-data-via-api-or-email)
(published 2 February 2026), and the
[Fuel Finder developer portal](https://www.developer.fuel-finder.service.gov.uk/access-latest-fuelprices)
(read 10 October 2026):

| | |
| --- | --- |
| Who | Comparison sites, app developers, researchers and individuals. |
| Registration | A [GOV.UK One Login](https://www.gov.uk/using-your-gov-uk-one-login), then an *Information Recipient* application in the developer portal, which issues a client ID and secret. Test and production credentials are separate. |
| Authentication | OAuth 2.0 client credentials, scope `fuelfinder.read`. The example token response has `expires_in: 3600` ([API authentication](https://www.developer.fuel-finder.service.gov.uk/fuel-finder/api-authentication)). |
| Data | Per forecourt: `node_id`, trading and brand name, address and postcode, **latitude and longitude**, motorway and supermarket flags, temporary and permanent closure, amenities, opening times, and per-grade prices with `price_last_updated` and `price_change_effective_timestamp` in UTC ([API fields guide](https://www.developer.fuel-finder.service.gov.uk/fuel-finder/api-guide)). |
| Grades | `E10`, `E5`, `B7_Standard`, `B7_Premium`, `B10`, `HVO`. The sample price `123.9` is pence per litre. |
| Endpoints | The portal's specification pages render client-side and could not be read without an account. Two independent open-source clients ([hoyla/fuel-finder](https://github.com/hoyla/fuel-finder), [niallel/fuel-finder-gov-uk](https://github.com/niallel/fuel-finder-gov-uk)) agree on base `https://www.fuel-finder.service.gov.uk`, token `POST /api/v1/oauth/generate_access_token`, stations `GET /api/v1/pfs`, prices `GET /api/v1/pfs/fuel-prices`, paged by `batch-number` in batches of 500, with `effective-start-timestamp` for changes since a time. They disagree on whether the body is a bare list or wrapped in `{"data": ...}`, so the relay accepts both. **Confirm the paths against the portal specification when the account exists**; the base URL is a setting. |
| Rate limits | 100 requests a minute per client and **one concurrent request**; HTTP 429 beyond that ([developer guidelines](https://www.developer.fuel-finder.service.gov.uk/fuel-finder/dev-guideline)). One of the clients above assumes 30 a minute. The relay stays far below both. |
| Caching guidance | "Station data: Cache for 1 hour." "Price data: Cache for 15 minutes" (developer guidelines). |
| Flat file | A CSV twice a day, downloadable from the portal page. The portal fetches it from an internal, undocumented endpoint, so the relay does not rely on it. |

### Licence, attribution and redistribution

- Registration as an information recipient accepts the
  [Open Government Licence v3.0](https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/)
  and the scheme's Fair Use policy. The policy itself sits behind the account;
  its wording was quoted publicly in the
  [OpenStreetMap community thread on Fuel Finder](https://community.openstreetmap.org/t/uk-gov-fuel-finder-open-data/141220)
  (9 February 2026). As quoted there, it requires data to be presented fairly,
  forbids manipulating, filtering or selectively displaying data to favour
  certain suppliers, forbids altering timestamps, and asks for a link to the
  discrepancy-reporting route.
- The developer guidelines add: "Don't redistribute raw API data." and
  "Attribute data sources appropriately."
- The OGL attribution statement is "Contains public sector information licensed
  under the Open Government Licence v3.0."

How the design meets those terms:

- **No raw redistribution.** The relay holds the full set only in memory and
  answers a bounded viewport with a reduced record: position, name, brand, and
  price and timestamps for the grades the app uses. There is no bulk or
  whole-country endpoint.
- **Timestamps are passed through unaltered.** The app shows the source's own
  price time, and separately the time the relay last confirmed it.
- **No supplier preference.** Ranking is by detour and price only, the same rule
  for every brand (see [Navigate to fuel](#navigate-to-fuel)). Nothing is
  filtered by brand.
- **Attribution and error reporting.** The layer shows the OGL statement and
  "Fuel Finder", and links to
  [Report an error in fuel prices or forecourt details](https://www.gov.uk/guidance/report-an-error-in-fuel-prices-or-forecourt-details).
- **Open question for the operator to put to the Fuel Finder team** (via the
  portal's [contact page](https://www.developer.fuel-finder.service.gov.uk/fuel-finder/contact-us)):
  that an app's own server caching prices for 15 minutes and serving them to
  that app's users per viewport is permitted use and not "redistribution of raw
  API data". The developer guidelines' own caching advice implies it is, but it
  is not stated.

### What the operator must do

1. Create a GOV.UK One Login if you have none.
2. Open the [developer portal](https://www.developer.fuel-finder.service.gov.uk/access-latest-fuelprices),
   choose the public API, and create an **Information Recipient** application
   for Tail End Charlie. Accept the OGL and the Fair Use policy only after
   reading the policy text, and save a copy of it to the issue (#951).
3. Copy the **production** client ID and secret into the relay host's
   `deploy/.env` (never into the repository):

   ```bash
   RIDE_RELAY_FUEL_FINDER_CLIENT_ID=...
   RIDE_RELAY_FUEL_FINDER_CLIENT_SECRET=...
   ```

   Pre-production takes the same names prefixed `PREPRODUCTION_`, with the
   **test** credentials.
4. Redeploy the relay. Within a few minutes `/api/v1/compatibility` lists
   `fuel-prices-v1`, which is what switches prices on in the app. Unset the two
   values to switch them off again without an app release.
5. Send the Fuel Finder team the question above and record the answer on #951.

## The CMA interim feeds

From mid-2023 the CMA asked the large retailers to publish a
`fuel_prices_data.json` file on their own sites, and listed them on
[Access fuel price data](https://www.gov.uk/guidance/access-fuel-price-data).
That page was **withdrawn on 1 May 2026** with the note that the interim scheme
had closed and the links to retailers' data had been removed; Fuel Finder
replaces it. The feeds covered only participating chains, carried no licence
beyond the page's OGL footer, and need not still exist. **Not used.**

## UK station locations

| | OpenStreetMap `amenity=fuel` | Fuel Finder station list |
| --- | --- | --- |
| Licence | [ODbL](https://www.openstreetmap.org/copyright), attribution "© OpenStreetMap contributors" | OGL plus the Fair Use policy; "Don't redistribute raw API data" |
| Credentials | None | Registration |
| Offline | Yes, bundled in the app | No, served by the relay |
| Completeness | Community-mapped; very good for UK forecourts, not guaranteed | Every forecourt that must report |
| Fuels sold | `fuel:diesel`, `fuel:octane_95`, `fuel:octane_98`, `fuel:e10` and so on, where tagged | Per-grade flags |

**Both, joined at run time.** The bundled layer, generated from OpenStreetMap by
`tools/discovery/generate_fuel_stations.py` in the same style as the speed
camera and mini-roundabout layers, is what a rider without signal sees. When
the relay answers with prices, the app matches each priced forecourt to the
nearest bundled station within 75 m and attaches the price. A priced forecourt
with no bundled match is still shown, from the relay's own position. Bundling
the Fuel Finder list would be redistributing raw API data, so it is never
written into the app.

The two are not merged into one dataset anywhere, which keeps ODbL and OGL
data separate.

## Chargers

### The statutory open data

[The Public Charge Point Regulations 2023](https://www.legislation.gov.uk/uksi/2023/1168/contents),
[regulation 10](https://www.legislation.gov.uk/uksi/2023/1168/regulation/10/made):

- Operators must make **reference data** (location, connector type, payment
  methods, **price in pence per kWh**, hours unavailable) and **availability
  data** (whether a charge point is working) public, **free of charge, machine
  readable and without any requirement to agree to terms and conditions**.
- Status must be updated within **30 seconds** of a change.
- The data standard is OCPI 2.2.1.

There is **no central endpoint**. The National Chargepoint Registry was
[decommissioned on 28 November 2024](https://www.gov.uk/guidance/find-and-use-data-on-public-electric-vehicle-chargepoints),
and DfT's later aggregation contract with Zapmap supplies data to the
department, not to the public
([Zapmap, September 2025](https://www.zapmap.com/news/dft-awards-zapmap-contract-deliver-electric-vehicle-chargepoint-open-data)).
Each operator publishes its own feed in its own place: some are open URLs, some
need an emailed key or HTTP Basic credentials, and some had not published a
URL at all when the
[OpenStreetMap wiki list](https://wiki.openstreetmap.org/wiki/EV_charge_points_in_the_United_Kingdom)
was last edited (30 August 2025).

Tariffs and live availability would mean finding, registering for and
maintaining dozens of OCPI feeds, each with its own failure modes. That is a
project of its own, best run on the routing VM (#917) rather than the relay.
**Not in build 103.** The rider sees "Tariff and availability not shown" on a
charger, never a guess.

### Open Charge Map

- Licence: its own contributors' data has been
  [CC BY 4.0 since 1 April 2022](https://community.openchargemap.org/t/announcing-our-new-simpler-data-license-for-ocm-data-cc-by-4-0-international/565);
  imported records keep their provider's licence, and checking each one is the
  user's responsibility.
- An API key is
  [mandatory for every read](https://community.openchargemap.org/t/reminder-api-keys-are-mandatory/218),
  and heavy users are asked to run a mirror instead.
- Mixed licences per record make it awkward to bundle beside ODbL data.

**Not used.** It is the most likely supplement if OpenStreetMap coverage proves
thin on rides.

### OpenStreetMap `amenity=charging_station`

ODbL, offline, no credentials. Connector types come from `socket:*` tags
(`socket:type2`, `socket:type2_combo`, `socket:chademo`, `socket:type2_cable`,
`socket:bs1363` and so on;
[tag documentation](https://wiki.openstreetmap.org/wiki/Tag:amenity%3Dcharging_station)).
A charger with no socket tags is kept and shown as "connectors not recorded",
not dropped. **Used** for build 103, in the same bundled layer as fuel.

## France: prix-carburants

[prix-carburants.gouv.fr open data](https://www.prix-carburants.gouv.fr/rubrique/opendata/):

| | |
| --- | --- |
| Licence | Licence Ouverte / Open Licence (Etalab 2.0): free reuse with attribution |
| Credentials | None |
| Feed | `https://donnees.roulez-eco.fr/opendata/instantane`, a ZIP of one XML file, about 0.9 MB compressed and 12 MB uncompressed (9,815 stations on 10 October 2026) |
| Update | Roughly every ten minutes |
| Coordinates | Integers in PTV_GEODECIMAL; divide by 100,000 |
| Prices | Euros per litre; grades `Gazole`, `SP95`, `SP98`, `E10`, `E85`, `GPLc`, each with its own `maj` timestamp in French local time |
| Names | Station names and brands are not in the feed, only the address |

This is simpler than Fuel Finder, so the relay supports it, off by default
(`RIDE_RELAY_FUEL_PRICES_FRANCE_ENABLED=true` turns it on). French stations are
**not** in the bundled offline layer in build 103: OpenStreetMap's French
charger data alone would multiply the asset's size. Online, the priced French
stations appear from the relay's positions.

## Architecture

### Relay

The relay (954 MB host, one worker) holds the price snapshot in memory:

- **UK.** A full station list at start-up and every six hours (the guidance's one
  hour is a cache ceiling, and forecourts rarely move). A full price load at
  start-up and daily; in between, changes since the last successful check every
  **15 minutes**, with a 45-minute overlap so a price reported at the end of its
  30-minute window is not missed. Requests are serial, at most one every three
  seconds: a full load is about 34 requests over two minutes.
- **France.** The instantaneous ZIP every 15 minutes, with `If-Modified-Since`.
- **Bounded.** At most 20,000 stations per source; response, ZIP and XML size
  caps; a viewport limited to 0.5° of latitude by 0.8° of longitude and 600
  stations. About 20,000 stations take a few megabytes of memory.
- **API.** `GET /api/v1/fuel/prices?west=&south=&east=&north=` returns the
  stations in the box with the grades the app uses, each price's own
  timestamps, the time the relay last confirmed the source, the attribution
  and the error-reporting link. Rate-limited per address like the traffic
  endpoint. Without a configured source it answers 503
  `fuel_prices_unconfigured`, and `fuel-prices-v1` is absent from
  `/api/v1/compatibility`.

The routing VM was considered and not chosen: a job there would need its own
public endpoint and secret handling for a dataset this small, and the relay
already has both. Charger OCPI aggregation, if it ever happens, belongs there.

### App

- **Fuel preference** in Settings: unleaded (E10), super unleaded (E5), diesel,
  or electric with the connectors the bike takes.
- **Map layer**, bundled and offline, drawn under the discovery layers'
  visibility rule (#846): shown while browsing and planning, hidden while
  navigating, **except** while the rider is choosing a fuel stop they asked
  for. It has its own switch in the layer menu (on by default), shows only
  stations for the rider's fuel, from zoom 10, at most 40 at a time on a
  budget separate from the café and road pins. Each pin carries the price and
  the time it was confirmed ("142.9p · 14:05"), dimmed with its date once
  stale, and nothing once unconfirmed; the pin's sheet has the full wording,
  the source's own report time, the credits and "Report a wrong price".
  Forecourts that Fuel Finder lists and OpenStreetMap does not are offered by
  Navigate to fuel but not drawn as pins.
- **Prices** only when the relay advertises `fuel-prices-v1`. That capability is
  the feature flag: the operator turns prices on and off from the relay.
- **Navigate to fuel / Navigate to charger** in Where to? and on the Plan
  surface.

### Price wording

A price is never presented as current when it might not be.

| State | Rule | Wording |
| --- | --- | --- |
| Current | The relay confirmed the source within the last hour, and the phone fetched it within the last hour | "142.9p · as of 14:05" |
| Stale | Either check is older than an hour | "142.9p on 3 Oct, may have changed", greyed, and ignored for ranking |
| Unconfirmed | The source's own timestamp for that price is more than 30 days older than the relay's check | "Last reported 2 Aug", greyed, ignored for ranking |

The source's own timestamp is shown unaltered in the station detail.

### Navigate to fuel

Candidates come from the bundled layer (plus relay-only priced stations), for
the rider's fuel. A station tagged as not selling the rider's fuel, a charger
with none of the rider's connectors, and a forecourt Fuel Finder lists as
closed are never offered. A station whose grades or connectors are not mapped
is kept. For unleaded (E10) and diesel, which nearly every forecourt sells, it
is treated as selling them; for super unleaded and for chargers it is marked
"not recorded" and ranked as if a kilometre further away.

- **With a route:** stations within 3 km of the route line and up to 80 km
  ahead of the rider along it. Navigating, that is the route still to ride;
  planning, it is the route from the rider if they are on it, or from its
  start. A route that passes a station twice uses the first pass.
- **Without a route:** stations within 25 km of the rider.

Each candidate's cost, in metres, is:

```
distance to reach it        (along the route, or straight-line × 1.3 without one)
+ 2 × detour                (there and back off the route line: 2 × offset × 1.3)
+ 500 m per penny per litre above the cheapest current price among candidates
+ 1 km if super unleaded or the connector is not recorded
```

The penny-to-distance rate means a station 4p a litre cheaper is worth 2 km
more riding. Stale and unconfirmed prices count as unknown and add nothing.
Brand is never an input. The top five are offered.

Where the rider finds it:

- **Where to?** on Home: "Navigate to fuel" or "Navigate to charger", worded
  from the preference.
- **Free-roam map menu** while following a route, with the same wording,
  because the search field is off the navigation canvas.
- **Plan surface:** the same button below the route options.

Choosing a station adds it as a stop on the leg nearest it, through the plan
surface like a café added from the map, so the changed route is seen before it
is used. With no route, it becomes the destination. A group ride that has
started has no search on its map; its leader can add a fuel stop by editing the
route on the plan surface.

## Coverage

- UK: OpenStreetMap stations and chargers offline; Fuel Finder prices once
  registered.
- Ireland, the Isle of Man and the Channel Islands: OpenStreetMap stations and
  chargers offline, no prices (outside Fuel Finder).
- France: priced stations online once enabled; no offline layer.

## Revisit when

- the Fuel Finder team answers the caching question differently;
- a public central charger endpoint appears, or the routing VM has capacity for
  an OCPI aggregator;
- OpenStreetMap charger coverage proves thin on a ride.

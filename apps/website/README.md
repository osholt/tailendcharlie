# Tail End Charlie website

This is the static marketing site and browser ride planner for
`tailendcharlie.app`.

The site uses no analytics, web fonts, cookies, or server-side user data.
`planner.html` uses pinned MapLibre GL JS, OpenFreeMap tiles, OSRM road routing,
Valhalla motorcycle routing for motorway, major-road, toll, and ferry
preferences, and user-triggered Nominatim searches. It includes a default-on,
toggleable catalogue containing the authorised Bike + Brew Passport 2026 Google
My Maps export plus locally maintained common starts. Exported venues are
retained only while they also appear on the event's current directory map, so
withdrawn or stale entries are excluded. Routes can be reshaped with visible,
reusable adjustment handles; the road route previews while a handle is dragged,
and route edits can be undone or redone. Direction arrows follow the route,
with larger arrows distinguishing each traversal near a self-crossing. Flowing,
twisty and very-twisty choices use a reproducible bend score and explicit detour
limits, documented in
[`docs/route-twistiness.md`](../../docs/route-twistiness.md). Catalogue matching
stays in the browser. Draft rides and preferences are retained in first-party
browser storage for save-and-return, with an in-planner clear control and no
cookies or tracking. Route coordinates and other place queries go only to the
documented providers.

Three default-off motorcycle discovery layers use the bounded Wales
proof-of-concept catalogue in `data/discovery-catalogue.geojson`. The planner
filters it to the current viewport, renders the planned route above the
highlights, and provides attribution, warnings and route-via-here actions.
Rider suggestions are queued in first-party local storage and never auto-send.
Set the `tec-discovery-api` meta value in `planner.html` to the deployed relay
origin to enable explicit submission. `admin-suggestions.html` is the no-index
authenticated moderation client; update its default API origin when deploying
the relay.

Cloudflare Pages is connected directly to this repository and publishes the
site automatically from `main`.

Refresh and revalidate the authorised catalogue with:

```bash
node scripts/refresh-bike-and-brew.mjs
```

Run the planner unit tests with:

```bash
node --test *.test.mjs
```

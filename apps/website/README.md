# Tail End Charlie website

This is the static marketing site and browser ride planner for
`tailendcharlie.app`.

The site uses no analytics, web fonts, cookies, or tracking storage.
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
cookies or tracking. A rider can explicitly create an eight-character app code;
that sends the generated GPX to the configured relay's existing encrypted plan
store for 30 days. The same code imports the route into the mobile app, and its
HTTPS planner link reopens an editable web copy or offers the route to an
installed mobile app through Universal Links/App Links. The email action opens
the rider's own mail client and does not send email from the website. Route
coordinates and other place queries go only to the documented providers.

The two association files are in `.well-known/`. The Apple entry is the
production team/bundle identifier. The Android entry currently contains only
the local debug signing certificate so physical development builds can be
verified; add the Play App Signing SHA-256 fingerprint from Play Console before
enabling the feature for closed testers. The upload-key fingerprint is not a
substitute because Play-distributed APKs are signed with the app-signing key.

Three default-off motorcycle discovery layers use the bounded Wales
proof-of-concept catalogue in `data/discovery-catalogue.geojson`. The planner
filters it to the current viewport, renders the planned route above the
highlights, and provides attribution, warnings and route-via-here actions.
Rider suggestions are queued in first-party local storage and never auto-send.
Set the `tec-discovery-api` meta value in `planner.html` to the deployed relay
origin to enable explicit suggestion submission and route-code sharing.
`admin-suggestions.html` is the no-index
authenticated moderation client; update its default API origin when deploying
the relay.

Cloudflare Pages is connected directly to this repository and publishes the
site automatically from `main`.

`observer.html` is the no-index, read-only watcher view. A rider can share one
phone's last-known status; a group leader can instead disclose a bounded live
roster, individual position freshness and planned-route outline. Both use a
time-limited link whose high-entropy secret remains in the URL fragment and is
sent only to the relay in an authorization header. The page never accepts a
ride join code or makes the watcher a participant. Released apps share the copy
served by their own relay host, so
production and pre-production credentials cannot cross environments. The
Cloudflare Pages copy uses the `tec-observer-api` meta value only as a
production-site fallback. Observer map requests are same-origin and fall back
to coordinates until the relay's optional map style/assets are installed.
The observer page serves its reviewed MapLibre GL JS 5.24.0 executable and
stylesheet from `assets/maplibre-gl-5.24.0/`; the upstream MIT licence is
vendored alongside them. It does not permit a third-party script origin.

Refresh and revalidate the authorised catalogue with:

```bash
node scripts/refresh-bike-and-brew.mjs
```

Run the planner unit tests with:

```bash
node --test *.test.mjs
```

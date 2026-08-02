# MapLibre styles

`ride-relay.json` is the observer map style, exposed as:

```text
https://<RIDE_RELAY_DOMAIN>/maps/styles/ride-relay.json
```

## Do not use relative source URLs

This file used to recommend relative URLs such as `../tiles/basemap/{z}/{x}/{y}`.
That advice was wrong, and following it produces a blank map.

MapLibre fetches tiles and glyphs from a web worker. A worker has no document
base URL, so a relative URL throws `Failed to construct 'Request'` inside the
worker: no failed request in the network panel, no MapLibre error event, nothing
in the console. The map simply never draws. To a safety contact that looks the
same as a ride with no position yet, which is why #281 stayed open as "the map
shows no roads".

Every URL the style hands to MapLibre must be absolute by the time the browser
sees it.

## How the host is filled in

The relay answers on more than one hostname - production, preproduction and a
local container - so the style is a Go template that Caddy renders per request:

```json
"tiles": ["{{placeholder `http.request.scheme`}}://{{placeholder `http.request.hostport`}}/maps/basemap/{z}/{x}/{y}.pbf"]
```

Two traps come with that:

- The `templates` directive only processes `text/html` and plain text by
  default. A `.json` style needs `mime application/json` declared, or it is
  served with its placeholders intact and MapLibre cannot parse them.
- The whole file is a template, so any `{{ ... }}` anywhere - including inside a
  metadata note - is parsed as an action and fails the render with a 500.

Use backticks for the placeholder arguments. Double quotes would need escaping
for JSON, and Go's template parser rejects the escaped form.

`apps/website/observer-basemap-style.test.mjs` covers all of the above.

## Why the tiles are proxied

The observer page shows a rider's live position, so the tiles it requests reveal
roughly where that person is. Fetching them straight from a third-party CDN
would disclose that to the CDN. The relay proxies them instead, under
`/maps/basemap` and `/maps/fonts`, which keeps the request inside a service that
already holds the ride and lets the observer page keep its strict
`connect-src 'self'`.

Attribution is required by the tile data's licence and lives in the style's
`sources.basemap.attribution`. Leave it there.

## Checking a deployment

```bash
tools/check-observer-basemap.sh https://relay.example.com
```

It asserts on content rather than status codes, because the upstream answers
`200` with a zero-byte body when the tile path is one component short, and a
zero-byte tile draws an empty map without raising an error.

## Moving to self-hosted tiles

`/maps/tiles/*` already routes to `martin`, which serves from `deploy/maps/data`
under the `maps` compose profile. Switching means putting an extract there,
enabling the profile, and pointing the style's `tiles` at `/maps/tiles/...`.
That is #274, and it is the only way to stop depending on an upstream service.
Do not deploy a style copied from a provider unless its licence permits
redistribution and offline region downloads.

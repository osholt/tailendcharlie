# Tail End Charlie website

This is the static marketing site and browser ride planner for
`tailendcharlie.app`.

The site uses no analytics, web fonts, cookies, or server-side user data.
`planner.html` uses pinned MapLibre GL JS, OpenFreeMap tiles, OSRM road routing,
Valhalla motorcycle routing for motorway avoidance, and user-triggered
Nominatim searches. It includes a small local starter catalogue of biker cafés
with stored map locations, clickable POI dots, and a link to the complete Bike
+ Brew venue directory. Routes can be reshaped with visible, reusable adjustment
handles; the road route previews while a handle is dragged, and route edits can
be undone or redone. Catalogue matching stays in the browser. Ride names and
generated GPX files also stay in the browser; route coordinates and other place
queries go only to the documented providers. Cloudflare Pages is connected
directly to this repository and publishes the site automatically from `main`.

Run the planner unit tests with:

```bash
node --test *.test.mjs
```

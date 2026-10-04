# Route preferences and the twistiness score

The twistiness score is a deterministic comparison aid, not a speed target or a
safety rating. It lets a rider compare road-route alternatives before accepting
the extra time and distance.

This document is the **single contract** for route preferences. There is one set
of preferences, not one per surface, and both clients implement this page:

| Surface | Implementation |
| --- | --- |
| Web planner | `apps/website/planner-core.mjs` |
| Mobile app | `apps/mobile/lib/domain/route_preferences.dart`, `apps/mobile/lib/services/route_twistiness.dart` |

The two implementations are pinned to identical constants by tests on both
sides, so a route planned with "avoid motorways" on the desktop and one planned
with it in the app mean the same thing and reach the same engine with the same
options. Changing a number here means changing it in both, and both test suites
will say so.

Preferences belong to the **route**, not to the device. The app stores them on
the route record and writes them to a `<tec:route-preferences>` metadata
extension in the GPX it exports; the web planner writes the same element into the
GPX behind a share code. A route shared into a ride therefore carries what it was
planned for, and is re-snapped to roads for the same preferences rather than
quietly acquiring a motorway on the next rider's phone.

## Metric

1. Read the road-following geometry and distance returned by the routing
   provider.
2. Sample the geometry at approximately 150-metre intervals.
3. Measure the absolute heading change at each sampled point.
4. Ignore changes below 8 degrees as geometry noise.
5. Ignore changes above 70 degrees as route manoeuvres. This prevents U-turns,
   roundabout exits and right-angle urban grids from being rewarded as useful
   bends.
6. Divide the remaining heading change by route distance in kilometres.

The displayed result is rounded and labelled:

| Score | Label |
| ---: | --- |
| below 12°/km | Gentle |
| 12–24°/km | Flowing |
| 25–44°/km | Twisty |
| 45°/km and above | Very twisty |

The reviewed South Wales catalogue provides stable calibration fixtures. Its
coarse A4069 Black Mountain and Gospel Pass road geometries both score about
15–16°/km. Full road-provider geometry is more detailed and can produce a
higher score, but repeated calculation of identical geometry always produces
the same result.

## Route choices and bounds

- **Quickest** keeps the provider's fastest alternative.
- **Flowing** may choose a bendier alternative up to 25% slower.
- **Twisty** may choose one up to 50% slower.
- **Very twisty** may choose one up to 75% slower.

Motorway, major-road, toll, ferry and byway controls remain independent of the
twistiness setting. OSRM is used for ordinary alternatives; exclusions use the
documented Valhalla motorcycle costing options. Each client selects only from the
alternatives a provider actually returns.

## Which engine answers

| Preferences | Engine |
| --- | --- |
| Defaults, or a style change only | OSRM `driving`, `alternatives=3` when a style has to choose |
| Any of motorways / major roads / tolls / ferries avoided | Valhalla `motorcycle` costing |
| Unsurfaced byways **allowed** | Valhalla `motorcycle` costing |

The four avoidances are exclusions the OSRM driving profile cannot express.
Allowing unsurfaced byways is on the list because only the motorcycle costing has
a lever for *seeking* them. The default request stays on OSRM so that every
ordinary route does not go through the shared Valhalla instance.

The default stays on OSRM **not** because OSRM avoids byways. It does not, and
this page used to say it did. On 4 October 2026 the public OSRM server routed an
untagged `highway=track` with gates, because it was shorter than the paved road
beside it (#840). Whichever engine answers, a preference is a request and not a
result: see [Checking the route that comes back](#checking-the-route-that-comes-back).

The Valhalla route deliberately carries **no turn instructions**. Valhalla numbers
its manoeuvre types where OSRM names them, and this app turns a manoeuvre into a
spoken instruction and a second-bike marker drop, so a mapping invented without a
verified fixture could state the wrong direction at a junction. Until that
fixture exists the route falls back to geometry-derived decision points, the same
as an imported GPX route, and the app says so in the route review warnings.

## Byways open to all traffic: the default and why

**Default: unsurfaced byways are avoided.**

A byway open to all traffic is a *legal* designation. OpenStreetMap records it as
`designation=byway_open_to_all_traffic`, and that tag says nothing whatsoever
about what the surface is made of: some BOATs are asphalt lanes, many are rutted
mud. So the preference is expressed against the surface tagging OpenStreetMap
actually carries — `surface=*`, and `highway=track` for a way mapped as a track —
and never inferred from the road's classification. That is why the option is
named for the surface (`avoid-unsurfaced` / `allow-unsurfaced`) rather than for
the legal right of way, and why it maps onto Valhalla's `exclude_unpaved`
(surface) and `use_trails` (track) options rather than onto a road-class filter.

Avoided is the default because Tail End Charlie coordinates **group** road rides:

- The cost of the wrong guess is asymmetric. A road-biased rider sent down a
  green lane on a loaded tourer or with a pillion stops, and a group ride that
  stops mid-lane on a single-track byway is a ride that has split.
- A group is mixed. One adventure bike in eight does not make a BOAT rideable for
  the other seven, and the planner cannot know the fleet.
- It matches the rest of the product. The discovery pipeline already excludes
  unpaved surfaces from its candidates
  (`EXCLUDED_SURFACES` in `tools/discovery/generate_catalogue.py`), so a road that
  is not good enough to suggest is not a road to route down by default either.
- The opposite default cannot be undone safely by a rider who did not expect it.
  A trail rider who wants byways knows they want them and can say so; a road
  rider who did not think to check finds out at the mud.

A trail rider turns the preference off, in the app or in the planner, and the
route may then use ways OpenStreetMap tags as unsurfaced or as a track.

What this does **not** claim: that either engine honours the preference. OSRM's
car profile penalises unpaved surfaces and does not refuse `highway=track`, and
the public Valhalla motorcycle costing was measured on 4 October 2026 to ignore
`exclude_unpaved` and `use_trails: 0` (the same request routed over a track that
`auto` costing avoids). The preference is therefore enforced by checking what
comes back. And a way OpenStreetMap has not tagged with a surface at all is
unknown, not paved — the same honesty rule the speed limit display follows.
Surface, width, gates and seasonal restrictions remain the rider's own check.

## Checking the route that comes back

*Mobile app only. The web planner has the same engine rule and does not yet check
its routes; its status line still words the byway preference as a result.*

A preference is sent to the engine and then **checked**, because neither engine
can be trusted to have honoured it. Every route a planner produces - a destination
plan, a reshape, a snapped GPX route, a circular loop - is looked up once with
Valhalla `trace_attributes` (`shape_match: map_snap`, because the line usually came
from OSRM over different map data). Each edge it returns carries its way, `use`,
`surface` and `unpaved`, and is classified:

| Found | Counts as | When |
| --- | --- | --- |
| `footway`, `path`, `cycleway`, `bridleway`, `steps`, `pedestrian` | Not a road | Always |
| `use=track`, or an unpaved surface (parking aisles and drives excepted) | Unsurfaced | Avoid unsurfaced byways is on |

A concern is excluded by position (`exclude_locations`: the middle of each
offending edge, at most 32) and the trip is asked of Valhalla **once more**. The
new route replaces the old only if it is checked itself, has at most half as much
of the offending road in it, and starts and ends within 150 m of where the first
did. Otherwise the original is kept. A circular loop is checked once, for the loop
the planner settles on, and is reported but not re-planned: a replacement would
have to pass the same closed-loop, distance, U-turn and overlap tests as any other
candidate. (The review then re-snaps it like any route made of route points, and
that route is checked and re-planned as above.)

Whatever is left is shown on the route review, with its length, and is never
hidden:

- `Uses 0.4 mi of unsurfaced track, although Avoid unsurfaced byways is on.`
  followed by `No road route that avoids it was found.` if the re-plan found
  nothing;
- `Could not check this route against your road preferences (...), so it may use
  roads you asked to avoid.` when the lookup failed or could not be trusted;
- `Only N of M could be checked` when the route is longer than one request can
  cover.

Limits, measured on the same instance:

- A route over **200 km** is refused whatever the number of points
  (`Path distance exceeds the max distance limit`). One request covers the first
  190 km, the rest is reported as unchecked, and a route is not split into more
  requests: it is a shared public instance and a plan is looked up once.
- A lookup is the route's geometry simplified to at most 1,500 points, with no gap
  over 250 m, and takes about 0.3-0.4 s.
- A matched road covering under half, or over 125%, of the line sent is not
  believed, and the route is reported as unchecked.
- A stretch under 20 m is not reported. Not checked: the short legs a ride makes
  to rejoin its route or reach its start, and service roads with no explicit
  vehicle access, which `trace_attributes` does not report.

The byway note on a route says what was **asked** ("Avoid unsurfaced byways") and
never what was achieved; whether it was achieved is the check's to say.

## Limitations

- The score describes geometry only. It does not prove that a road is open,
  surfaced, unrestricted, scenic or safe.
- Provider geometry and distance can change when its underlying road data or
  routing version changes.
- Semantic roundabout and junction metadata is not present in every route
  response, so the manoeuvre-angle filter is deliberately conservative.
- Elevation, bend radius, temporary restrictions, traffic and weather are not
  currently part of the score.
- The stated detour bound is based on provider duration, not a promise about
  real traffic conditions.

Road signs, closures, conditions and the rider's judgement remain
authoritative.

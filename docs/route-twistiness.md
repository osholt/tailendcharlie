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

The four avoidances are hard exclusions the OSRM driving profile cannot express.
Allowing unsurfaced byways is on the list for the opposite reason: the standard
OSRM car profile does not route `highway=track` at all, so *seeking* byways is
the case OSRM cannot serve, while avoiding them is the case it already serves.
That keeps the default request on OSRM instead of putting every route through the
shared Valhalla instance.

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

What this does **not** claim: an OSRM route with the default preference rests on
the standard car profile refusing `highway=track` and penalising unpaved
surfaces, which is weaker than an exclusion. Only the Valhalla path applies
`exclude_unpaved` as a hard constraint. And a way OpenStreetMap has not tagged
with a surface at all is unknown, not paved — the same honesty rule the speed
limit display follows. Surface, width, gates and seasonal restrictions remain the
rider's own check.

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

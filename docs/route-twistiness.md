# Route twistiness score

The web planner's twistiness score is a deterministic comparison aid, not a
speed target or a safety rating. It lets a rider compare road-route
alternatives before accepting the extra time and distance.

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

Motorway, major-road, toll and ferry controls remain independent of the
twistiness setting. OSRM is used for ordinary alternatives; exclusions use the
documented Valhalla motorcycle costing options. The planner selects only from
the alternatives a provider actually returns.

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

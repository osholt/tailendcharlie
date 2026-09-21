# Build 101 circular routes and discovery validation

Candidate date: 21 September 2026. Release tracked by #833; implementation issues
#670 and #832. The user authorised pushing the fixes to testers. Field-dependent
issues remain ready for validation until the reporter rides the new build.

## Circular routes (#670, direction clarification #644)

The selected compass direction describes the loop's overall area. Separated
outward/return controls, wider alternatives and resizing every control replace
the narrow shared stem. A bounded six-candidate search scores complete route
geometry, rejects unintended reversals and excessive repeated road, and keeps
its best valid result if an optional alternative fails. “Try another loop” moves
to a different batch. Web control geometry uses the same construction.

A complete-route quality check covers atomic provider responses that contain no
U-turn instruction. Distance correction runs before final quality acceptance;
it cannot release a route that fails the final checks. Intentional access to an
explicit stop is excluded, while duplicate provider vertices cannot hide a
reversal. Closely spaced but distinct hairpin arms are tested separately.

Motorway exclusion can produce a technically routable but enormous detour around
a crossing. Atomic routing now applies the existing excessive-detour exception,
retains the requested road style, and discloses relaxed motorway avoidance in the
preview. This is a general rule, with no location-specific geometry. Provider
integration continues to use documented Valhalla through locations:
https://valhalla.github.io/valhalla/api/route/api-reference/

Live public-provider probes used a coarse Bristol origin and 80-mile NE/NW
requests with Direct, Twisty and Very twisty, avoiding motorways. All six final
requests generated closed routes without detected unintended reversals. The
returned distances and repeated-road percentages were:

| Direction | Preference | Distance | Repeated road |
| --- | --- | --- | --- |
| NE | Direct | 128.114 km | 0.00% |
| NE | Twisty | 111.710 km | 0.35% |
| NE | Very twisty | 110.428 km | 0.35% |
| NW | Direct | 116.618 km | 1.65% |
| NW | Twisty | 147.052 km | 3.10% |
| NW | Very twisty | 134.625 km | 4.88% |

All requests were for 128.748 km; existing distance tolerance is 30%. NE cases
completed in under a second; NW cases took about 29–32 seconds while trying
alternatives. The provider and network determine actual wait time.  Route quality is not a guarantee for every road network: access roads and
limited crossings can require some overlap, and a usable loop is still refused
when every candidate fails. Private screenshots and GPX files were not published.

## Motorcycle discovery (#832)

The former zoom-12.5 cutoff hid sparse, useful regional discoveries. Regional
views now select markers by logical pixel spacing, clipped to the viewport,
with a bounded count and shared café/road budget. Category interleaving prevents
cafés from consuming every slot. Global views remain suppressed. Selection
refreshes with zoom and pan; saved layer switches still apply.

The same selection runs in the native ride map, Flutter fallback, native route
preview and Flutter review. Native and Flutter tile sizes are accounted for.
Route start/end/shaping controls are never culled or included in the discovery
budget. The existing compact icons and tap details are retained; business-name
pills and widened base roads are not reintroduced.

## Verification

- Targeted routing, density, actual map and preview widget regressions pass.
- Mutations caught: disabling atomic geometry rejection; restoring zoom 12.5;
  disabling marker separation; counting deliberate-stop access as overlap.
- A completed read-only Grok review identified early quality rejection, explicit
  stop overlap and category starvation; each has a regression test and correction.
- Full mobile suite: **2,286 passed, 24 existing skips**. Static analysis: no
  issues. Formatting: 544 files unchanged. Website suite: **92 passed**.
  Workflow links are recorded on #833.
- Projected-navigation incremental compliance reports no structural/traceability
  failures. Existing physical-platform gaps remain ticketed.

## Release gate

Require all seven protected-main checks, deploy the relay at the exact merged
app commit and verify `serverBuildCommit`, then publish build 101 to TestFlight
external testers and Android alpha (`notification_mode=dry-run`). Verify actual
store availability; an upload alone is not tester availability. No new physical
phone, sunlight, CarPlay or Android Auto validation is claimed.

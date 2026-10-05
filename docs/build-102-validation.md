# Build 102 validation: 4 October ride feedback

Release tracked by #863. Source: the build 101 group ride to Penelope's Cafe on
4 October 2026, solo Where To diagnostics from the same day, and the tester chat.
The operator requested this build. Every issue stays `status: ready for
validation` until it is ridden; nothing here is field evidence.

Each issue PR merged into `claude/build-102` with a root cause, a general rule
(no location special cases), junction-local recorded fixtures, and mutation
tests that were all caught. Details are in each PR and its issue comment.

## Navigation

| Issue | Root cause | General rule | Field check |
| --- | --- | --- | --- |
| #853 | The #302 bearing override let a −4° heading change overrule the engine's `turn left` at an 8° diverge. The parser had discarded the junction's other branches. | Keep each manoeuvre's junction. Where another legal branch leaves within 30°, state the side ("Keep left/right"). An engine-stated side is never reversed. | Usk → Chepstow, B4235 slip: "Keep left" |
| #851 | The #774 detector invented a fork wherever a branch left within 60°: every motorway slip and many B-road junctions. A step type was shown as a road name. | No fork where the road carries on by number or name. "Follow the road" where no other road is nearly as straight. Leaving the main road keeps its side. Empty road labels stay empty. | Aust → Bristol, B4235: no fork prompts |
| #856 | "1st exit, left" was correct. The turn detail paired the engine's ring-entry bearing with the route-line exit bearing, contradicting the instruction. | Direction and capture share one approach/departure pair, with its source recorded. | A capture at Aust reads "slight left" |
| #839 | Reshape and GPX enrichment sent shaping points as stops, so every leg ended in an arrival. | Shaping points are routed as pass-through (OSRM `waypoints=`, Valhalla `through`). Only named stops and the destination arrive. Integration also strips shaping arrivals behind the route-checking service, with a test. | Dragged shaping point: no arrival prompt |

## Routing safety

| Issue | Root cause | Change | Field check |
| --- | --- | --- | --- |
| #840 | The default plan used OSRM on a false belief that it avoids `highway=track`. Public Valhalla ignores `exclude_unpaved`. Nothing checked the returned route. | One `trace_attributes` check per plan. Re-plan once with `exclude_locations`; otherwise a route-review notice. Home and CarPlay plan through the same service. | Re-plan the café route |
| #858 | Home planned through OSRM alone, so the avoidances never left the phone. | Valhalla `exclude_highways`, plus the same check naming any unavoidable motorway | Bristol → Stroud, avoiding motorways |
| #852 | The live sign reads OSM `maxspeed`; the 20 mph limits are mapped. The discovery tool mapped `GB:nsl_restricted` to 30 even in Wales. | Jurisdiction-aware restricted-road limit, and the `tools/speed_limit_audit` operator tool | Export ride 360670 and run the audit |

## Bluetooth evidence (#855)

A per-rider ledger records which transport delivered each event and position
first. The roster shows "Bluetooth N s ago · Internet N s ago". The ride-ended
screen gives a verdict, and the diagnostics log gains TRANSPORT lines. Four
causes of missing or overwritten group-ride diagnostics were fixed. The
definitive airplane-mode check is in `docs/field-test-plan.md`; record the
results on #268.

## Group communication

- #849: one-tap REPORT sends an "Alert" to everyone. It is logged with time,
  place and sender, shown on the ride review and previous rides, and exported as
  GPX waypoints. It is sent as an `other` hazard plus a `kind` key, so build 101
  shows "Other hazard" rather than failing to decode.
- #854: leader-only "TELL GROUP" broadcasts. Receiving phones admit them only
  from the leader at that point in the journal; each is delivered once per event
  and expires after 10 minutes. Build 101 shows the relayed label as a card.
- Gap: no push to a backgrounded phone (#881).

## Map and layout

- #842: one line order for both renderers; the leader trail draws above the route.
- #846: discovery layers are hidden while navigating; saved preferences are
  untouched.
- #844: one palette for the main map and the overview.
- #841: road-edge contrast in the light styles goes from 1.45–1.55:1 to about
  2.0:1. Measured tables are in `docs/maps-and-gpx.md`.
- #848: portrait ETA strip and overview moved into the bottom band; chrome text
  scale is capped. The leader's REPORT and TELL GROUP stack so the overview stays
  at least 120 pt wide.
- #850: minimap setting, on by default for the leader and the TEC. An explicit
  choice wins.
- #843: Android marker images were sized as one-to-one bitmaps although MapLibre
  draws them at device density. The halo filled the SDF square, and the badge lay
  on the tilted map plane. All three are fixed, with density tests from 1 to 4.
- #845: the leader and the resolved TEC are drawn as stars on the phone maps and
  the overview. CarPlay and Android Auto still draw circles.
- #860: unnamed EV chargers and parcel lockers whose provider name contains an
  identifier get a generic label. The upstream OSM fix is the operator's.
- #900: Android trail arrows (about 7 dp, iOS 18) and hazard/alert badges
  (about 15 dp, iOS 44) were sized the same way as #843. Both are fixed, with
  density tests at 7 pixel ratios.

## Location sharing (#859)

A started ride nobody ends used to share indefinitely. A pure dispersal rule now
protects real riding, café stops, waiting markers and a TEC far behind. It asks
after 30 minutes of dispersal and pauses sharing 15 minutes after the rider stops
moving. It also adds a persistent sharing indicator and a background
notification.

## Planning flow (#847 phase 1)

The Plan surface: the start defaults to your location and can be changed, named
stops, dragged shaping points kept out of the stop list, and route options with
Solo/Group on one screen. A confirmed route can be edited. Solo↔group conversion
keeps navigation running. No new relay event types. Later phases are #891–#899.

## Release gate

1. Require every protected-main check on the combined PR.
2. Deploy the relay at the exact merged commit and verify `serverBuildCommit`.
3. Dispatch TestFlight build 102 (external) and Android build 102 (`alpha`,
   `notification_mode=dry-run`).
4. Verify actual store availability on #863.

No physical-phone, sunlight, CarPlay or Android Auto validation is claimed.

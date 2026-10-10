# Build 103 validation: open beta candidate

Release tracked by #963; the open beta it launches is #861. Sources: the 10
October morning ride diagnostics, the operator's 10 October requests, and the
planning-flow phases left over from build 102 (#891–#899).

Each issue PR merged into `claude/build-103` with its own tests and mutation
results in the PR body. Nothing here is field evidence: every issue stays
`status: ready for validation` until it is ridden or seen on a device.

## Ride feedback, 10 October

| Issue | Root cause | Change | Field check |
| --- | --- | --- | --- |
| #616 | Three fallback-voice prompts. The prompt's distance moved while the natural voice was rendering, so the rendered audio no longer matched and the robot voice spoke instead. | A prompt keeps its rendered audio when only the distance moved (#925). | A ride with no robot-voice prompts in the diagnostics |
| #942 | Three prompts dropped. A prompt rendered at speed was discarded when the rider slowed before it played. | The rendered prompt is kept and plays (#945). | No missing prompts at junctions approached while braking |
| #941 | On-route was judged by distance alone, so a rider crossing the route got its directions. | Directions only for a rider travelling along the route, by heading (#947). | Cross a planned route at a junction: no prompt |
| #940, #444 | Where To had no rerouting; leaving the route left the rider with a stale line. | Where To reroutes back onto the planned route when the rider leaves it (#950). | Leave a Where To route on purpose: a new line within seconds |

## Map and search

| Issue | Change | Field check |
| --- | --- | --- |
| #935 | Route start, stop and end markers stay upright as the map turns (#938). | Rotate the map in navigation |
| #936 | The follow camera zooms with speed, closer around town (#946). | Town then A-road: zoom changes smoothly |
| #953 | Rendered tiles are kept in memory and only the settled zoom level is drawn (tiles PR). | Pinch fast in and out on a downloaded region on an iPhone |
| #937 | Search history (last ten) and saved places (Home, Work, custom) in Where to? (#954). Stored on the phone only. | Save Home, search, clear history |
| #913 | The global heatmap is pink to crimson, distinct from discovery blue (#915). | Open the global heatmap |
| #912 | Leader and Tail End Charlie drawn as stars on CarPlay and Android Auto (#932). | Head unit, group ride |

## Fuel and charging (#951)

- The decision record is `docs/fuel-and-charging-data-decision.md` (#952).
- The relay caches official prices and serves them per viewport (#955). This is off until the operator registers with Fuel Finder and sets the credentials; the relay's `fuel-prices-v1` capability is the switch.
- The offline OpenStreetMap layer has 10,161 fuel stations and 7,435 charger sites for the UK, Ireland, the Isle of Man and the Channel Islands (#960).
- **Navigate to fuel** or **Navigate to charger** follows the fuel preference in Settings (#961).
- Map pins show a price and its age (#962).
- There are no charger tariffs or live availability.

Field check: with prices off, pins show no price and Navigate to fuel still ranks by detour. After the operator enables prices, compare three pins with the forecourt boards.

## Planning flow (#891–#896)

- Drag stops to reorder them, and drag a stop's pin (#916).
- Re-plan an edited route from the rider's position (#921).
- Rename a ride, and the last route options are remembered (#923).
- **Open with** sits beside the confirm button (#924).
- A solo leg and its group ride file as one ride (#928).
- Imported tracks open on the plan surface (#931).

## Demo and replay

- A demo ride's pre-start is one slim **Start ride** bar (#949, #933).
- The demo route is selectable, UK Cotswolds or France, and remembered (#956, #934).
- A finished ride's own timed track can be replayed (#958, first slice of #305). This build has no group replay.

## Group, platform and open beta

- Leader broadcasts and rider alerts are pushed to backgrounded phones (#918, #881). This needs real push credentials (#38) before it can be seen.
- Per-platform minimum app build with an **Update required** screen (#922, #37).
- The build number is required and checked against the store (#914, #630).
- Routing and geocoding endpoints come from the relay (#926, #927, #929, #917). The phones keep the public services until the operator's routing VM passes its smoke test and the relay variables are set.
- Open beta (#861):
  - Play open-testing gate, with Android Auto as an explicit build switch, off (#939).
  - TestFlight public-link workflow (#944).
  - Launch runbook, store answers, minimum age 17 and beta support at `testing@tailendcharlie.app` (#948).
- Global heatmap contribution is asked at setup and stays off until the rider chooses (#959, #957).
- The privacy page describes fuel-price requests by coarse map area.

## Release

Follow `docs/open-beta-launch.md` and the steps on #963. Record the store and
deploy evidence on #963.

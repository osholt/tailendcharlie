# Ride planning flow (#847)

Status: design, written 4 October 2026 for build 102. Phase 1 ships in build 102;
later phases are recommended child tickets of #847.

Source: the group ride to Penelope's Cafe on 4 October 2026 (build 1.0.1+101).
The operator's words:

> When creating a ride there are too many ways to create a ride and not enough
> ways to change a solo ride into a group ride or vice versa or go back to edit a
> route after you have confirmed it. In some views it's not possible to choose a
> start point. Ideally it should work exactly the same way as Google Maps on
> mobile works, where you can type a destination and it defaults to your current
> location for a start point but you can always change it and add named stopping
> points. Then in the map view you can draw the route around with shaping points
> that don't show up in the list of waypoints. This all needs reconciling and
> making a lot more coherent with a big plan and rewrite taking the best of what
> we already have.

This document maps every way a route or ride is created today, sets out one
model to replace them, and says what happens to each existing entry point. It
absorbs #600, #581, #579, #605, #624 and #626 (items 3 and 6), and builds on #242
(drag reshaping), #261 (coordination modes) and #839 (shaping points routed as
non-stopping controls).

## 1. What exists today

The app has two top-level surfaces, chosen by `RideRelayApp`:

- **Free roam**: `HomeScreen` over `HomeMapBackdrop`, a `RideMapFeature` with
  `RouteAuthority.personal`. No ride exists. A route on this map *is*
  navigation (#600).
- **A ride**: `ActiveRideShell`, with a ride-scoped route store and the leader's
  route published to the journal (`routeRevisionChunk` and
  `routeRevisionPublished`).

Routes reach either surface through `RideMapScreen`'s pipeline:
`_reviewAndActivateRoute` → `RouteReviewScreen` → `_commitRoute`. Free roam
receives routes from Home through `PendingInAppRoute` plus a change token; a
ride receives them through `SharedRouteController` and the same token.

### 1.1 Every entry point

| # | Entry point | Where | What it does | Problems |
| --- | --- | --- | --- | --- |
| E1 | Home **Where to?** search | `HomeDestinationSearchSheet` → `HomeScreen._navigateTo` (`home_screen.dart:838`) | Destination result → `DestinationRouteSheet` (a text form: optional start, stops, destination, preferences, "Open route with") → `DestinationRoutePlanner.planForReview` → handed to the free-roam map → `RouteReviewScreen` → free-roam navigation. | Two screens in a row (form, then review). The review opened from this path has `canEditStops: false`, so stops cannot be edited where the route is shown. With no GPS fix every search result is disabled (`home_destination_search.dart:258`), although the form behind it accepts a typed start. Home's planner is plain OSRM (`home_screen.dart:316`), so "avoid motorways", "avoid major roads", "avoid tolls", "avoid ferries" and "allow unsurfaced" are silently ignored, while the route still records those preferences. No way to make it a group ride. |
| E2 | Search-sheet handoffs | `HomeSearchHandoffKind` | Circular ride → map's circular planner. Recall a planned route → **the ride-creation form**. Join with a code → join form. A route already on this phone → Ride Library → **the ride-creation form**. | Choosing a saved route or a web-planner code forces the rider to create a ride (and answer Solo/Group, ride name and rider name) before seeing the route. The same route imported as a GPX does not. |
| E3 | Home menu: **Create a group ride** | `HostMapMenuAction('home-create-ride')` → `_RideForm(creating: true)` | Form: Solo/Group, coordination mode, ride name, plan code, rider name; group → share-code step. | Does not carry the route the rider is navigating. Offers "Solo", which creates a solo *ride*, a second way to ride alone beside free roam. |
| E4 | Home menu: **Ride library** | `_openRideLibrary` (`home_screen.dart:910`) | `StoredRoutePickerScreen` (tidied/raw/reverse) → **ride-creation form**. | Same forced ride creation as E2. Inside a ride the same library goes straight to review. |
| E5 | Free-roam map menu | `RideMapScreen` overflow with `hostChrome` | Create a circular ride; Import/Replace GPX; Load demo route; Remove route. | "Remove route" in free roam asks "Clear the group route? … for every rider" (`_confirmRemoveRoute`, `ride_map_feature.dart:8537`), though there is no group. |
| E6 | Circular planner | `_planCircularRide` (`ride_map_feature.dart:6871`), `CircularRideSheet(start:)` | Loop from the current position. | **The start cannot be chosen.** With no fix it refuses ("Enable location so the circular ride can start and finish here"). |
| E7 | GPX file, "Open in…", web-planner deep link | `SharedRouteController` | Free roam: a banner offering **Save** to the library only. In a ride (leader): a change-route request → review. | Different results for the same file depending on whether a ride exists. |
| E8 | Map café / discovery "route via" | `_addBikerPlaceToRoute`, `_addDiscoveryFeatureToRoute` (`ride_map_feature.dart:7943`, `:8003`) | Appends a new leg from the **end** of the current route (or from the current position) to the place, then reviews. | The destination silently moves to the café; the place is never inserted as a stop. The start cannot be chosen. |
| E9 | In a created ride, before the start | `_PreStartRidePanel` "Choose route"/"Change"; the empty-route card (`_EmptyRoutePrompt`); the map's **Where to?** field (`showDestinationSearch`); start dialog "Choose route" | All open the change-route sheet or `_planDestination` (form → review with `canEditStops: true`). | "Edit stops" in that review returns to the **text form** and loses every stop added on the map and every shaping point drawn (the form only holds query strings). |
| E10 | In a ride: Ride tab **Change route** | `_RideActionsPanel` → `_requestRouteChange` → `_showChangeRouteSheet` (`ride_map_feature.dart:8647`) | Plan a destination / Use a saved route / Import / Replace GPX / Load a planned route / Load demo route / Remove route. | Every option **replaces** the route from scratch. There is no "edit this route": its stops, shaping points and preferences cannot be reopened. |
| E11 | Solo ride ↔ group | #261's **Join group** beside Start (unstarted solo only) | Leaves the empty solo ride and opens the join sheet. | There is no "invite others" from a solo ride, nothing once it has started, and nothing from free roam. The free-roam upgrade that carried the route (`_rideWithOthers`, #600) was removed on 20 August (`b592df9`) and replaced by E3, which does not carry it. The earlier upgrade also re-reviewed the route it was carrying (#624). |
| E12 | Group → solo | Leave or end ride | Leaving ends navigation. | A rider who wants to carry on alone along the group route has no way to keep it. |
| E13 | CarPlay | Home: destination search/preview → **creates a solo ride** and publishes the route; "Free roam" → creates and starts a solo ride named "Free roam". In a ride: leader destination preview (pre-start only), Start prepared ride. | Free roam on CarPlay is a ride; on the phone it is not. Kept unchanged in phase 1 (Apple compliance work is in flight under #690–#699). |
| E14 | Onboarding | `OnboardingScreen`: Take me to the map / Create a ride / Join a ride | "Create a ride" opens the E3 form. | A fourth door into the same form. |
| E15 | Web planner code | E2, the change-route sheet "Load a planned route", deep links | Fetches a GPX by code. | Three different prompts for one action. |
| E16 | Imported GPX shaping points | `GpxParser` (`<gpxx:ShapingPoint>`) | Stored as `RouteWaypoint`s with symbol `Shaping point`. | Listed as stops in "Route points" and routed as stops (the leg-split side of this is #839). |

### 1.2 Where the start point cannot be chosen

1. Circular planner (E6): always the current position.
2. Home search with no GPS fix (E1): results disabled, although a typed start
   would work.
3. Café and discovery "route via" (E8): the end of the route, or the current
   position.
4. Route review, from every source: start and destination are read-only.
5. Ride library, previous rides and GPX imports: the file's start is fixed (the
   #262 "Navigate to start" connector helps only after confirming).
6. CarPlay: the current position. This is correct in a car and stays.

## 2. The target model

### 2.1 Principles, taken from Google Maps mobile

1. **Destination first.** Typing where you are going is the way in. Nothing about
   rides, codes or modes is asked first.
2. **The start defaults to your location** and is always editable. A missing
   GPS fix never blocks choosing a destination; it only means the start row says
   so and offers a place instead.
3. **Named stops** can be added, reordered and removed in one list.
4. **Shaping points** come from dragging the line on the map. They are never in
   the stop list, are never announced as arrivals, and are routed as
   non-stopping controls (#839).
5. **One surface.** The same screen plans a new route, reviews an imported one
   and edits a confirmed one.
6. **Solo or group is a property of the plan**, chosen on that surface, and can
   change before or during the ride.
7. **Confirming is not final.** "Edit route" reopens the same surface with the
   same stops, shaping points and preferences.

### 2.2 The plan

`RidePlan` (new, `lib/domain/ride_plan.dart`) is the rider's intent:

| Field | Meaning |
| --- | --- |
| `start` | `CurrentLocationStart` (default) or `PlaceStart(place)` |
| `stops` | Ordered named places (`RidePlanPlace`: point, label, description, symbol) |
| `destination` | A named place, or none yet |
| `shapingPoints` | `RouteShapingPoint`s; `legIndex` counts legs of `[start, ...stops, destination]` |
| `preferences` | `RoutePreferences` (the web planner's contract, unchanged) |
| `coordinationMode` | `solo` (default), `secondBikeDropOff` or `keepTogether` (#261's modes) |

A plan has no store of its own. **A confirmed plan is an `ImportedRoute`**, as
every route already is:

- `waypoints` are `[start, ...stops, destination]`, in order, named.
- `shapingPoints` are the shaping points, with their leg indexes.
- `preferences` are the preferences.
- A start that was "your location" is written as the existing
  `DestinationRoutePlanner` convention (name `Start`, description
  `Current location`), so routes planned by today's builds round-trip.

`RidePlan.fromRoute(route)` reverses that, so "Edit route" works on any route the
app planned, including routes received from a leader and routes saved before
this change. Its rules are general:

- A waypoint whose symbol is `Shaping point` (GPX `<gpxx:ShapingPoint>`, E16) is
  a shaping point on the leg it falls in, not a stop.
- A route with fewer than two named waypoints (a recording or a plain track)
  takes its start and destination from the ends of its line, and the surface
  says that editing re-plans it on roads.
- A start described `Current location` comes back as "your location", so an
  edit made mid-ride re-plans from where the rider is now, as Google Maps does.
  A chosen start stays that place. The start row switches between the two.

Editing rules are pure functions of the plan, so they are unit-tested without a
map:

- Adding a stop inserts it before the destination. A stop added from the map
  (a café or discovery pin) goes on the leg nearest to it.
- Shaping points survive every edit. Adding a stop splits a leg, and each
  shaping point on it moves to whichever half it lies nearer. Removing a stop
  merges two legs. Moving a stop is a removal then an insertion.
- Changing the start or the destination keeps the shaping points.

`RidePlanRouter` (new, `lib/services/ride_plan_router.dart`) turns a plan into a
route. It sends `[start, ...stops with their shaping points, destination]` with
the shaping indexes through `ShapingPointRoadRoutingService.routeThroughShapingPoints`
(OSRM `waypoints=`, Valhalla `through`), the API the circular planner already
uses and #839 extends to the reshape planner and the GPX enricher. Only named
stops split legs, so only named stops produce arrivals. It uses the
preference-aware service (Valhalla when a preference needs motorcycle costing),
which fixes E1's ignored preferences.

### 2.3 The Plan surface

The Plan surface is `RouteReviewScreen` in **plan mode**. Every existing review
feature stays: the map preview, "Draw route around" (#242), undo and the
adjustment chips, nearby cafés and discovery highlights as stops (#578), the
marker plan (#179), twistiness, warnings, "Another" for circular routes, and all
turns. Plan mode adds four things:

1. **Itinerary**, replacing the read-only "Route points" list: a start row
   ("Your location" by default, **Change** opens a place search with "Your
   location" at the top), one row per named stop (a drag handle to reorder,
   and remove), a destination row (**Change**), and **Add stop**. Shaping
   points never appear here; they stay on the map and in the "Route
   adjustments (not stops)" chips. While drawing, the start, a stop or the
   destination can also be dragged by its pin on the map (#891): the places
   keep their order, so every shaping point stays on its leg. A nudge of up to
   150 m keeps the place's name; a longer drag makes it a "Dropped pin".
2. **Route options**: the preferences that used to live in the destination
   form, applied immediately by re-routing. The options a rider last
   confirmed are a new plan's default (#894); an edited route keeps its own.
3. **Who's riding**, where the host allows it: Solo or Group, and for a group
   Second-bike drop-off or Keep-together (#261's wording).
4. **One confirm button named for what it does**: Start (solo), Create group
   ride (group), Use route (a ride that has not started), Update route (a ride
   under way).

Place search on the surface is the same submit-only Nominatim search as Home
(`docs/geocoder-decision.md`): results arrive when the search is submitted,
never per keystroke, and a test enforces that.

### 2.4 Sources feed the Plan surface

| Source | Becomes |
| --- | --- |
| Where to? search result | A plan to that destination from your location |
| Map's Where to? field, Plan a destination, Enter destination (in a ride) | A place search, then the same |
| Café or discovery pin "add to route" | The current plan with that place inserted as a stop; a new plan to it when there is no route |
| Circular planner | Unchanged generator, now with a start row; its loop reviews on the same screen |
| GPX import, Ride Library, previous rides, web-planner code | The existing choices first (Add turn directions?, tidied/raw, reverse), then the Plan surface with the route's line kept exactly until the first edit (#892); the itinerary says that an edit re-plans it on roads between the listed places. In free roam without first creating a ride |
| Edit route | `RidePlan.fromRoute(current route)` |

### 2.5 Solo and group

Solo and group are a property of the plan and of the ride, not a choice of door.

| From | Action | Result |
| --- | --- | --- |
| Plan surface, Group | Create group ride | A group ride is created with the plan's mode, the route is published in the same step, and the invite (code, Copy, Share) is shown. The ride waits in the lobby, as today. |
| Free roam, navigating | **Ride with others** | A group ride is created, the route is published, and **the ride is started at once** so guidance never stops. The invite is shown over the running map. |
| Free roam, no route | Ride with others | A group ride in the lobby, as today's "Create a group ride". |
| A solo ride (CarPlay or older builds) | Ride with others | The solo ride is filed in My rides and replaced by a group ride carrying its route; started at once if the solo ride had started. |
| A group ride, any rider | **Ride on alone** | A rider leaves the group; the leader either ends it for everyone or leaves it to the others (#176's no-leader state lets someone take over). Either way the group route is handed to free roam and navigation continues solo. |
| A group lobby, the leader | Ride solo instead | The same as Ride on alone. |

All of these use events the relay already accepts (section 4). The joining
side is unchanged: joining stays a six-digit code or a QR invitation, beside the
search field.

### 2.6 Edit route after confirming

| Who | Where | Effect |
| --- | --- | --- |
| Solo (free roam) | Map menu, and the ride-menu button on the navigation canvas: **Edit route** | Plan surface; Update route replaces the free-roam route in place. Navigation continues. |
| Leader, before the start | Pre-start panel **Change**; Ride tab **Edit route** | Plan surface; Use route publishes a new revision. |
| Leader, during the ride | Ride tab **Edit route** | Plan surface on what is left of the ride (#893): the start is the leader's position, and the stops and adjustments already behind the leader (measured on the navigation progress tracker's line, so a loop's finish is not its start) are dropped. Update route publishes a new revision without the ridden part. A leader not yet on the route (no progress, more than 250 m from it) keeps the meeting point. Riders behind the leader are guided back by the existing off-route rejoin (#102). Solo navigation edits the same way. |
| Follower | none | The route belongs to the leader. Ride on alone gives a follower their own copy to edit. |

The other route sources stay available as **Replace route** (the existing
change-route sheet), below Edit route.

### 2.7 Shaping points

- Drawn by dragging the line in "Draw route around" mode (#242), dragged again
  to move, removed from their chip, undone with Undo.
- Stored in `ImportedRoute.shapingPoints` with leg indexes; never in
  `waypoints`; never in the itinerary; never announced (#839).
- Routed through the non-stopping API (`RidePlanRouter`, and the reshape planner
  once #839 lands).
- Imported GPX shaping points are classified the same way by `RidePlan.fromRoute`.

## 3. Disposition of every entry point

| # | Entry point | Disposition | Phase |
| --- | --- | --- | --- |
| E1 | Home Where to? | **Kept** as the way in. The text form between search and review is **removed**: the result opens the Plan surface. Results are enabled with no GPS fix. | 1 |
| E2 | Search-sheet handoffs | **Kept**: circular, join and saved routes. Saved routes and plan codes go to free roam's review instead of the ride form. | 1 |
| E3 | Create a group ride | **Merged** into Ride with others (carries the route; starts the ride when navigating). | 1 |
| E4 | Ride library on Home | **Kept**; no longer forces ride creation. | 1 |
| E5 | Free-roam map menu | **Kept**; gains Edit route and Ride with others. "Remove route" says "Stop navigating" in free roam. | 1 |
| E6 | Circular planner | **Kept**; gains a start row. | 1 |
| E7 | GPX, Open in…, deep links | **Kept**. Free roam still offers Save; opening it to ride goes through review. | 1 (unchanged) |
| E8 | Café / discovery route via | **Merged** into the plan: inserted as a stop on the nearest leg. | 1 |
| E9 | Created-ride planning | **Merged**: Where to? and Plan a destination open place search then the Plan surface; Change opens Edit route. | 1 |
| E10 | Change route sheet | **Kept** as Replace route; Edit route is added first. | 1 |
| E11 | Solo → group | **Replaced** by Ride with others in every solo state. #261's Join group stays. | 1 |
| E12 | Group → solo | **Added**: Ride on alone. | 1 |
| E13 | CarPlay | **Kept unchanged** in phase 1. Phase 3 makes CarPlay free roam navigation-without-a-ride and offers Edit route from the phone. | 3 |
| E14 | Onboarding Create a ride | **Merged** into Ride with others. | 1 |
| E15 | Web-planner code prompts | **Merged** into one "Recall a planned route" action feeding review. | 1 |
| E16 | GPX shaping waypoints | **Fixed** in the plan model (never listed as stops). Routing semantics are #839's. | 1 |
| — | `DestinationRouteSheet` form | **Removed**; its preferences move to the Plan surface's Route options. "Open route with" stays as "Navigate or export route" after confirming, and is offered beside the Plan surface's confirm button as **Open with** (#895), which hands over the route on screen and leaves the plan open. | 1 |
| — | `_RideForm` create mode (Solo/Group, ride name, plan code) | **Removed** once nothing reaches it; its join mode stays. Solo becomes free roam; group becomes Ride with others; plan codes become Recall a planned route. The ride name defaults to the route name. | 1 |
| — | Solo *rides* (`RideCoordinationMode.solo` sessions) | **Kept** for CarPlay and restored sessions; the phone no longer creates them. | 3 |

## 4. Event journal and relay compatibility

Phase 1 adds **no event types and no relay change**.

- **Route publication** is unchanged: `routeRevisionChunk` and
  `routeRevisionPublished` carry the whole `ImportedRoute` JSON, which already
  includes `waypoints`, `shapingPoints` and `preferences`. A plan therefore
  reaches every rider intact, and a follower's phone can rebuild it with
  `RidePlan.fromRoute`. Any later plan fields must be additive JSON;
  `ImportedRoute.fromJson` ignores keys it does not know, so older builds keep
  working.
- **Late joiners** replay the journal and take the latest revision
  (`RideRouteReducer`). Route chunks have the relay's default retention (72 hours),
  longer than a day ride.
- **Editing mid-ride** is a new revision from the leader, exactly what the
  change-route sheet and CarPlay already publish. Followers' maps follow the
  authoritative revision; riders behind a moved start get the existing
  off-route rejoin (#102), and a pre-start rider far from the start gets the
  #262 connector.
- **Solo → group** creates a new ride (new ride id, code and invite secret)
  with `rideCreated`, then the route revision, then `rideStarted` when the rider
  was navigating. Creating and then publishing is the order CarPlay already
  uses from Home, and the shell already applies a revision or a start that
  arrives before or after it mounts. The solo part is filed
  as it is today: free-roam navigation in My rides via `FreeRoamRideRecorder`,
  a solo ride via the archive. Since #896 the group ride's session remembers
  the leg it carried on from (local only, never in the journal), and filing
  joins the two into one My rides record under the later ride's id: both
  legs' time, distance and tracks (as separate paths), the earlier record
  removed once the joined one is written. Riding on alone does the same in
  the other direction: free roam's navigation names the group ride it
  carried on from. Filing is idempotent across checkpoints and replayed
  journals, so a leg is never filed twice or dropped.
- **Group → solo** is `riderLeft` (a rider, or a leader leaving it to the
  others) or `rideEnded` (a leader ending it). Riding on alone is free-roam
  navigation, which writes nothing to any journal.
- **Why not convert a ride in place.** A `coordinationModeChanged` event would
  keep one ride id across the change, but it needs a new relay event type, a
  capability to negotiate it, and a rule for older builds, which would ignore
  it and keep showing a solo ride's controls to people who have just joined a
  group. That is phase 3, not build 102.
- **CarPlay** projections are unchanged: a converted group ride is an ordinary
  started ride with a published route.

## 5. Phases

### Phase 1: build 102

Four pull requests against `claude/build-102`, each stacked on the last.

1. **This design** (`claude/issue-847-planning-design`).
2. **The Plan surface** (`claude/issue-847-plan-surface`): `RidePlan`,
   `RidePlanRouter`, place search, plan mode on `RouteReviewScreen`, Home
   Where to? straight into it, solo confirm into free roam without a second
   review (#624's silent hand-off), group confirm creating the ride with its
   route, in-ride planning, the circular planner's start row, preference-aware
   routing on Home, and the removal of `DestinationRouteSheet`.
3. **Edit route and sources** (`claude/issue-847-edit-route`): Edit route in
   free roam and in a ride (pre-start Change, Ride tab), Replace route below it,
   café and discovery pins inserted as stops, saved routes and plan codes into
   free roam rather than the ride form.
4. **Solo ↔ group** (`claude/issue-847-solo-group`): Ride with others from free
   roam (started at once when navigating), from a solo ride and from
   onboarding; Ride on alone; the ride form's create mode retired.

What phase 1 deliberately leaves alone: the active-ride map chrome (#533, #125,
#133), CarPlay, the relay, and the riding-time layout work in #848.

### Phase 2: build 103

- Drag-to-reorder handles on the itinerary (phase 1 uses up and down buttons),
  and drag a stop's pin on the map.
- Imported tracks open in the Plan surface with the original line kept until
  the first edit, instead of the separate review.
- Mid-ride Edit route trims the ridden part for the group, rather than
  re-planning from the original start.
- A ride rename on the Ride tab (the ride name now defaults to the route name).
  Shipped in #894 as a label on this phone: no rider reads the leader's name
  from the journal, so renaming records no event.
- Remember the rider's last route options as the default for the next plan.
- One exit vocabulary across states: Leave (me), End (ride), Stop (navigating)
  (#626 item 6).

### Phase 3: later

- CarPlay and Android Auto: destination search on the head unit becomes
  free-roam navigation without a ride, Ride with others stays a phone action,
  and the head unit shows Edit route's result as an ordinary revision.
- In-place coordination-mode change (`coordinationModeChanged`) behind a relay
  capability, so a solo ride can become a group without a new ride id.
- Retire solo *rides* entirely once CarPlay no longer creates them.

## 6. Recommended child tickets

1. Phase 2: itinerary drag handles and dragging stop pins on the map.
2. Phase 2: imported tracks open in the Plan surface, keeping the original line
   until the first edit.
3. Phase 2: mid-ride Edit route for a group re-plans from the leader's position
   and keeps the ridden part out of the new revision.
4. Phase 2: rename a ride after creation; remember the last route options.
5. Phase 2: one exit vocabulary, Leave / End / Stop (#626 item 6).
6. Phase 3: CarPlay and Android Auto planning without a ride (with #690–#703).
7. Phase 3: `coordinationModeChanged` relay event and capability for in-place
   solo ↔ group conversion.
8. Phase 3: stop creating solo rides; migrate restored solo sessions.

## 7. Evidence that will validate phase 1

Automated tests cover the plan model, the router's requests, the Plan surface
flows and the conversions. These need a phone and a ride:

- Search a destination with GPS on: the start reads "Your location" and the
  route starts at the bike. Change the start to a meeting point, add two named
  stops, reorder them, remove one: the line follows each change.
- Drag the line onto another road: an adjustment appears on the map and in the
  adjustment chips, never in the stop list, and riding it produces no arrival
  prompt at the adjustment.
- Search with GPS off: results are tappable, the start row asks for a place,
  and choosing one plans the route.
- Navigate solo, tap Ride with others: the code appears, navigation and the
  voice do not stop, and a second phone joining late receives the route.
- In a group ride, a follower taps Ride on alone: they leave the roster and keep
  navigating the same route on their own.
- Confirm a route, then Edit route: the same stops and adjustments are there;
  add a stop and update. In a group, the followers' maps change to the new
  revision.

# Tester release notes

One section per tester build, newest first, keyed by the **build number** the
app shows under **Settings → About & build**. Testers reach this file from
**What changed in this build** on that screen.

Android build numbers are Play version codes and come from the
`Android internal testing` workflow's run number (or its `build_number` input).
iOS build numbers come from the `TestFlight` workflow the same way, so the two
platforms do not share a numbering sequence - always say which platform a build
number belongs to.

## How to add an entry

The `Android internal testing` workflow prints a draft (version, build number,
stamped track, commit, run link, whether closed testers can install it, and
recent commits) to its **run summary** and uploads it as the
`tailendcharlie-tester-release-notes` artefact. Copy the tester-facing parts into
a new section here, newest first, using the template below, then commit it.
Nothing publishes automatically - the workflow has read-only repository
permissions by design.

```markdown
## Android build <version-code> — <version> — <date>

### What to test

1. ...

### Fixed

- ...

### Known limitations

- ...
```

## iOS build 73 / Android build 73 — 21 August 2026

This build keeps circular rides on the requested kind of roads section by
section and makes the route-review map easier to use.

### What to test

1. **Create an 80-mile circular route to the northwest with Twisty and Avoid
   motorways enabled.** The route should be built as several independently
   costed sections. If a motorway is unavoidable, only the blocked section
   should relax that exclusion and the preview should say how many sections
   were affected; the rest of the loop should retain the motorcycle settings.
2. **Press Another on the circular-route review.** Stay on the review screen
   while a replacement route is created, then see the new route and updated
   statistics without returning to the planner.
3. **Pan and zoom the review map.** One-finger dragging and pinch-to-zoom should
   work immediately. Drawing a custom route should start only after choosing
   **Draw route around**.
4. **Check the review header.** The full ride name should have its own line,
   with Another and Confirm on the separate action row below it.

### Fixed

- Relaxing Avoid motorways once applied the relaxed settings to the entire
  circular ride, which could turn most of an otherwise twisty loop into
  motorway routing.
- Another closed the circular-route review instead of generating another loop.
- The editable preview opened in route-drawing mode, so normal map panning and
  pinch-to-zoom did not work.
- The ride name shared a narrow row with every action and was almost completely
  truncated.

### Known limitations

- A section that cannot be routed with Avoid motorways may still use a
  motorway. The preview warns when this happens so the route can be inspected
  before it is accepted.

## iOS build 72 / Android build 72 — 21 August 2026

This follow-up makes circular-route creation recover automatically when the
first loop shape contains a U-turn or avoiding motorways leaves no usable path.

### What to test

1. **Create an 80-mile circular route to the northwest with Avoid motorways
   enabled.** The planner should try alternative loop shapes rather than fail
   immediately when one contains a U-turn.
2. **Review the generated route before accepting it.** If no usable route can
   be made while excluding motorways, the preview should still open and clearly
   warn that Avoid motorways was relaxed and the route may use motorways.
3. **Repeat the same request.** It should not reproduce the earlier bare 400 or
   immediate U-turn failure. If neither the original nor relaxed request can
   make a usable loop, the error should suggest changing direction or distance.

### Fixed

- A circular-route retry started from the same loop shape, so the same U-turn
  could fail repeatedly.
- The planner rejected a route as soon as one candidate contained a U-turn
  instead of trying alternative loop geometry.
- Avoid motorways could make an otherwise possible circular ride fail instead
  of retrying with that one exclusion relaxed and warning the rider.

### Known limitations

- A fallback route is allowed to use motorways but is not guaranteed to use
  one. Check the warning and inspect the route carefully before accepting it.

## iOS build 71 / Android build 71 — 20 August 2026

This follow-up replaces an unexplained circular-route 400 error with guidance
that says which route setting to change.

### What to test

1. **Create an 80-mile circular route to the northwest with Avoid motorways
   enabled.** If the loop cannot cross the available road network, the app
   should explain that no circular route was found and suggest turning off
   Avoid motorways, changing direction or reducing the distance. It must not
   display a bare 400 error.
2. **Turn off Avoid motorways and retry.** Around Bristol, the northwest route
   should reach the normal route preview at approximately the requested
   distance. Check the route carefully before saving it.

### Fixed

- The routing client discarded Valhalla's useful “No path could be found”
  response and showed only its HTTP 400 status.
- Circular-route planning did not translate a provider no-path response into
  advice relevant to the route controls.

### Known limitations

- The app does not silently relax a rider's road exclusions. A northwest loop
  around the Severn may genuinely require a motorway crossing; in that case the
  rider must explicitly turn off Avoid motorways or choose a different loop.

## iOS build 70 / Android build 70 — 20 August 2026

This follow-up restores the map's persistent navigation controls in portrait
and landscape without bringing back the busy full-width bars.

### What to test

1. **Navigate in portrait.** The clock should stay at the top centre and the
   speed/compass circles at the top right. ETA and the group overview should
   begin below that row rather than pushing the clock down the screen.
2. **Open the menu while navigating in both orientations.** The top-left menu
   button should remain visible on the full-screen moving map. It must provide a
   way to Settings and the other app destinations in free roam and during an
   active ride.
3. **Check the landscape safety controls.** SOS ALERT, LEAVE and REPORT should
   remain visible and usable in the bottom-left area while the menu stays at the
   top left.

### Fixed

- Portrait put the navigation clock below the ETA card and left speed/compass
  in the bottom-right corner.
- Entering the full-screen moving map could hide the only route to Settings and
  other menus.
- The active-ride menu sat below the portrait ETA card, where it looked like
  part of the trip summary instead of a persistent navigation control.

### Known limitations

- The roundabout and landscape camera changes from builds 68 and 69 still need
  confirmation on the reported roads during a physical ride.

## iOS build 69 / Android build 69 — 20 August 2026

This build declutters the phone map and makes saved routes and spoken guidance
feel more like finished navigation features.

### What to test

1. **Open the home map on a small phone.** There should be one top bar: Where
   to remains readable, Join is compact, and there is no emergency-info button
   or permanent Ride with others bar at the bottom. Group-ride creation remains
   under `…` → **More actions**.
2. **End a ride, then leave its summary.** The ended-ride banner now has a close
   button. Closing it must remove the banner without losing the ride from Ride
   Library.
3. **Open map layers and zoom out.** Personal ride heatmap is on by default for
   anyone who has not previously chosen a setting. Motorcycle roads and biker
   cafés disappear on wide-area views and return when you zoom back in.
4. **Tap Where to.** **Create a circular ride** is now presented with the other
   route-creation choices and opens the existing circular-route planner.
5. **Open Ride Library.** Saved-route thumbnails and the tapped preview should
   show real map tiles behind the route. The large preview can be panned and
   zoomed; **Use this route** stays reachable at the bottom.
6. **Navigate with voice enabled.** Arrival should sound like “you'll arrive at
   your destination” or “your destination is just ahead”, not “you will reach
   the destination”. If the natural voice misses its deadline, the rest of that
   ride should stay on the same system voice instead of alternating.

### Fixed

- The home map repeated ride creation in a large permanent bottom bar and
  squeezed Where to between too many top-bar controls.
- An ended-ride banner could be reopened but not cleared.
- Personal heatmap started off, while discovery overlays stayed dense at every
  zoom level.
- Circular rides lived in a separate map menu instead of the Where to flow.
- Ride Library previews showed route geometry on a blank background.
- Arrival wording sounded mechanical, and a slow natural voice could alternate
  with the system voice from one instruction to the next.

### Known limitations

- The public global heatmap still publishes a cell only after at least three
  contributing riders overlap there. Until enough riders opt in, an empty
  global layer is expected and protects individual ride privacy.
- Build 68's roundabout and landscape fixes are unchanged. The automated
  regressions pass, but the reported roads and an on-bike landscape ride still
  need physical confirmation.

## iOS build 68 / Android build 68 — 20 August 2026

Everything in this build comes from one 48-minute ride around Bristol on build
67 — six fixes from that ride's reports and diagnostics, plus a full
consistency review of the app that the ride prompted. Thank you, Oliver.

### What to test

1. **The screen never sleeps while the app is open.** Anywhere — the home map,
   free roam, menus, mid-ride. It used to stay awake only inside a started
   ride, so free roam timed out mid-navigation. It should still sleep normally
   once you leave the app or lock the phone.
2. **Landscape, on the bike.** Three separate fixes land here:
   - your bike sits in the **right third** of the frame (UK riding), not the
     left — it was deciding the traffic side by majority vote over per-step
     data that came back wrong for two thirds of a British ride;
   - **SOS ALERT, LEAVE and REPORT sit in the bottom-left corner**, not
     floating mid-screen over the road ahead;
   - the rider marker clears the bottom bar instead of hiding behind it.
3. **Roundabouts.** Directions are now read from the roads either side of the
   junction rather than from bearings measured on the ring itself. The ring
   road crossing at Deanery Road / A420 that said *"2nd exit, right"* when it
   is plainly straight on was the proof case — ride it again if you can. Exit
   numbers were never wrong and are untouched.
4. **Stopping in free roam.** The ETA card now carries **Stop navigating** —
   one tap, one confirmation, route gone. It used to be "Remove route" behind
   the unlabelled `…` menu, which nobody found in 48 minutes of trying.
5. **The `…` menu on the home map** now sits at the end of the row, after
   Join / emergency / settings, where a menu belongs.
6. **This email itself** should have arrived from "Tail End Charlie", not a
   bare address.

### Fixed

- The display slept everywhere except inside a started ride (#607).
- Landscape framed British rides for right-hand traffic — bike in the left
  third (#613).
- Landscape floated SOS/LEAVE/REPORT to the middle of the screen on every solo
  ride — an invisible zero-size mini-map was reserving the corner (#619).
- The follow camera never counted the home screen's bottom bar, so the marker's
  lower edge sat behind it in landscape (#608).
- Roundabout directions came from bearings measured on the ring, contradicting
  the junction's own exit number and the rider's eyes (#614).
- Free roam had no findable way to stop navigating (#615).
- The map's overflow menu hid mid-row on the home screen, which read as the
  menu having been removed (#606).
- Home offered "Ride with others" over a still-running set-aside ride, and
  pressing it created a second ride; it now offers the way back instead (#605).

### Known limitations

- **The consistency review filed more than this build fixes.** Still open, in
  rough priority order: ending a ride asks the same question twice (#620);
  creating a ride mid-navigation drops your turn directions and demands a
  review (#624); solo rides get the group's No-TEC warning (#625); the
  pre-ride landscape header letterboxes the map (#623); the ride-ended screen
  clips under the camera housing in landscape (#622). All reproduced with
  screenshots on the issues.
- **Spoken directions** still mix voices (#616) — not started; the diagnostics
  don't yet record which voice spoke, so that instrumentation comes first.
- **Android Auto** is unchanged from build 67, tiles and all.

## iOS build 67 / Android build 67 — 18 August 2026

**Android Auto, for the first time.** Keith reported it not working while CarPlay
does, and he was right — three separate reasons, two of them in the app and one in
Google Play. All three are fixed. **Keith, this build is mostly for you.**

iOS is unchanged apart from the free-roam work already in build 66.

### What to test — Android Auto

1. **Does it appear at all?** Plug into your head unit. Tail End Charlie should be
   in the Android Auto app list. Until today the app was never offered to Android
   Auto by Play, whatever the phone did, so this is the first question and
   everything else depends on it.
2. **Open it from the car with the phone app closed.** Do not open the app on the
   phone first. It used to say *"Waiting for ride status — open Tail End Charlie
   on the phone"*, because the phone app owned the only running copy of the app's
   brain and nobody had started it. It should now come up on its own.
3. **A long ride with the phone in a pocket.** It used to go to *"Phone status is
   stale"* about two minutes in, for the same reason. It should stay live for the
   whole ride now. This is the one that most needs a real ride rather than a
   driveway.
4. **The map.** You should see the route, the part you have ridden in grey, the
   part still to come in orange, the rest of the group in their own colours, and
   your own bike with a nose showing which way you are pointing. **There are no
   roads or place names behind it** — see Known limitations.
5. **The turn card and the arrival strip.** Distance to the next instruction, the
   road name, and an ETA. The ETA comes from the phone, so it should match the
   phone exactly rather than being a second opinion.
6. **Where to?** Search for somewhere from the car at a standstill. The phone does
   the searching and the routing, so results and any error messages should read
   the same as on the phone.
7. **Ride / Start ride.** With no ride, **Ride** starts free roam. With a ride set
   up but not started, **Start ride** starts it — and if the phone will not let
   you, it should tell you why in the phone's own words.
8. **Group.** One press from the map. Whoever needs attention is at the top.

### Fixed

- The app was never offered to Android Auto by Google Play at all. Nothing in the
  app could have fixed that.
- Android Auto only ever showed a list of text rows — no map, no turn card. It had
  been that way since the feature was first added and never grew with CarPlay.
- The app's brain stopped whenever Android reclaimed the phone screen, which took
  the car surface stale with it.
- Your bike was drawn as a plain dot with no heading, on a north-up map, so there
  was no way to tell whether the line ahead of the dot was in front of you or
  behind.

### Known limitations

- **No roads or place names on the Android Auto map.** The route, the group and
  your bike are drawn on a plain background. CarPlay gets to reuse the phone's map
  directly; Android Auto hands over a bare canvas and the map has to be rebuilt on
  it, which is a bigger job and is being done separately. Tell me whether the
  route-and-group view is enough to ride with, because that genuinely changes how
  much the tiles matter.
- **None of the Android Auto work has run on real hardware.** The Android emulator
  ships a placeholder version of Android Auto with nothing behind it, so this is
  the first time this code meets a real head unit. Expect rough edges and please
  report them rather than assuming they are known.
- **No SOS, leave-ride or hazard reporting on the car screen.** Deliberate. Those
  are safety-critical on a bike and I would not add them without being able to
  test them first. Use the phone.
- The **iOS** side of this build is unchanged from 66.

## iOS build 66 / Android build 66 — 17 August 2026

**You no longer need a ride to go somewhere.** Open the app, tap **Where to?**,
pick a place, and you are navigating — turn-by-turn, on your own, with no code
and nobody to wait for. Riding with other people is a button you press
afterwards, and it brings your route with it.

This build also fixes the reason the **⋯** menu kept vanishing.

### What to test

1. **Search and go.** Tap **Where to?**, type somewhere, pick it, confirm the
   route. You should be navigating: turn instructions, distance to the next one,
   an ETA, and **Follow me** to lock the camera on the bike. Count the taps that
   mention a *ride* on the way — there should be none. Nothing asks whether you
   are solo.
2. **The ⋯ menu, standing still.** This is the one to check first. Open the app
   and let it find you. The top bar — **Where to?**, **⋯**, **Join**, emergency
   info, settings — should stay put. It used to disappear the moment the app
   knew where you were, which is why the layer menu behind **⋯** "never
   appeared". Confirm **⋯** is there before a ride, with a route loaded, and
   after a restart.
3. **Riding with others, from a route you already have.** While navigating
   somewhere, the bottom bar reads **Ride this with others**. Press it. You
   should get a ride code and the *same* route, already loaded — check the
   distance and the destination match what you were following. It should also
   put drop-off marker positions on it, which a solo route does not have.
4. **Your bike, your colour.** After **Ride this with others**, check the map
   marker is the motorcycle, symbol and colour you chose in setup. Searching for
   a destination used to quietly give you the default rider.
5. **Free roam is a map.** No **Choose a route** card over it on opening. If you
   have not granted location yet, **Show my location** is bottom-right as before.
6. **Settings, by name.** **More → Settings**, as well as the gear in the top
   bar. In a ride it is a tab; it should be a word you can read in both.
7. **Nothing hidden under the bottom bar.** The compass and the zoom controls
   should sit fully above **Ride with others**, not half-clipped behind it.

### Fixed

- The **⋯** menu, the search field, **Join** and the settings gear all vanished
  as soon as the app had your location, standing still. This is the cause of the
  layer menu being reported missing twice, and of there being no way to anything
  else from the map.
- Searching for a destination created a ride — with a coordination mode it had
  to ask about — before it would show you a route.
- Searching for a destination lost the motorcycle, symbol and colour you picked
  in setup.
- Free roam opened behind a **Choose a route** card written for a group ride.
- With a route loaded, the top bar ran off the side of a phone. **Fit route** and
  **Navigate or export route** are in the **⋯** menu when that happens.
- The map's compass and zoom controls were drawn behind the bottom bar.

### Known limitations

- **Not ridden.** Checked end to end in the simulator, which stands still — so
  nobody has seen what the screen does when you actually start moving in free
  roam with a route. That is the main thing to watch.
- **The café and good-road markers look wrong at some zoom levels** — stretched
  blobs a county or two out, and thousands of them covering the map when you
  zoom out to the whole country. Known, being fixed separately; ignore it for
  now unless it stops you testing something.
- The bottom bar still says **Ride with others** rather than offering a ride
  with no destination at all. If you want to set off with the group and no plan,
  that is what it does — it just does not say so.

## iOS build 65 / Android build 65 — 17 August 2026

The rest of the 17 August feedback: sheets you can back out of, layer controls
that are actually somewhere, a recovered-ride prompt you can dismiss, and setup
that lets you go straight to the map.

### What to test

1. **Backing out of a place.** Tap a café or a good-road highlight on the map.
   There is a **✕** at the top of the sheet now. Close it and confirm your route
   is untouched. Try it on a road with a lot of detail — the ✕ should stay put
   while you scroll rather than disappearing off the top.
2. **Choosing which layers show.** **Settings → Map layers**, near the top.
   Turn the cafés or a road type off and confirm the map changes and the choice
   sticks after a restart. This works during a ride too, which the old ⋯ menu
   could not: there is no top bar once navigation is running.
3. **The "ride recovered" prompt.** If the app finds a ride still running when
   it opens, the prompt now sits at the top and has a third option: **Not now —
   take me to the map**. Take it. You should land on the map with nothing
   nagging you. Then **More → Rejoin ride NNNNNN** to go back into it. Nothing
   is shared while it is set aside.
4. **Starting a ride from the search.** The **Where to?** field is the way in.
   Tap it and it takes the whole bar; **Join a ride with a code** is underneath.
   **Join** sits beside the field for when you have a code and no destination.
   The bottom bar now only offers **Start without a destination**.
5. **First-run setup** (needs a fresh install, or Settings → replay the guide).
   The last step offers **Take me to the map** as well as the two ride options.
   Take it and you should land on the map having committed to nothing.

### Fixed

- A café or highlight sheet could only be escaped by adding it to your route.
- The layer controls were not reachable during a ride at all, and could silently
  do nothing when they were.
- One failed file read used to remove every map layer *and* your saved layer
  choices, with nothing said.
- The recovered-ride prompt sat in the middle of the screen and offered no way
  out but rejoining or ending.
- Setup insisted on creating or joining a ride before it would let you through.
- The More menu clipped its last entry on shorter screens.

### Known limitations

- Nothing here has been on a physical phone. It is covered by automated tests
  only; the simulator was not available for this round.
- **Turning an imported GPX into turn-by-turn directions was fixed in build 64**
  and still wants a real ride to judge it — the turns are counted, not followed.
- The set-aside ride is reached from **More**, not from a banner. If that turns
  out to be too well hidden, say so.

## iOS build 64 / Android build 64 — 17 August 2026

Turning an imported GPX into turn-by-turn directions now works. It never has
before — the app was asking a routing service for far more than it would accept,
and every attempt failed. This build also puts the good-roads and café layers on
the route review screen, and tidies up how you choose a destination and leave a
ride you have not started.

### What to test

1. **Import a GPX and generate a navigable route.** Import one of the Mid-Wales
   day-run files and choose **Generate navigable route** when asked. It should
   produce a route with turn instructions along the roads the recording actually
   used — around 130 turns for a 300 km day — rather than the error you got in
   build 63. Ride or simulate part of it and check the turns come in the right
   places.
2. **The review screen's layers.** When reviewing a route, look for a
   **Good roads** chip beside **Nearby places**. Switching a layer off in the
   map's ⋯ menu should switch it off here too — it is the same setting, not a
   second one. Tap a highlight and add it as a stop; the route should
   recalculate through it.
3. **Leaving a ride you have not started.** Create a ride and do not start it.
   **LEAVE** should be on the map, without opening a menu. Check the
   confirmation says the right thing for a solo ride, as a leader, and as
   someone who joined.
4. **Asking for a destination.** In free roam and in a created-but-unstarted
   ride, the **Where to?** field should be in the same place and look the same.
   They still do different things — free roam's plans a ride around somewhere,
   the ride's adds a stop to the route in hand — but you should not have to hunt
   for a different control. Once a route is loaded its name replaces the field,
   and once the ride starts nothing about the riding screen changes.

### Fixed

- **Generate navigable route** failed every time. The app now matches imported
  tracks against a service that can take them, splitting long rides up and
  picking up again wherever the matcher stops.
- A failed match now says what the service actually objected to, instead of
  showing a bare error number.
- A file containing both a recorded track and a planned route was silently given
  no option to add turn directions at all.
- The route review screen could not show the discovery layers, which is the
  moment a stop usually gets chosen.
- Leaving a ride before it started meant digging through the ride menu.

### Known limitations

- The road matching is judged against the imported line, and a route that comes
  out too far from it is refused rather than shown. If a file is rejected,
  please send it — the numbers in the message are useful.
- Nothing on this list has been on a physical phone. It is covered by automated
  tests and by running the real files against the live routing service, which is
  not the same as riding it.
- Choosing a route inside a created ride and in free roam now offer the same
  control in the same place, but they still do different things by design.

## iOS build 63 / Android build 63 — 16 August 2026

The fixes from the ride of 16 August. The controls above the map no longer sit
on top of each other, a rider alone on the map can add a café or a good road to
their own route, a large GPX no longer buries its own track, and free roam can
find you again without restarting the app.

> Builds 57 to 62 went out without an entry here. This one covers the 16 August
> fixes only, not everything since build 56.

### What to test

1. **The controls above the map.** Open the app and look at the top of the
   screen. There should be one row — the search field, a **⋯** menu, emergency
   info and settings — with nothing overlapping. Tap **⋯** several times from a
   cold start and confirm **Motorcycle discovery layers** opens *every* time.
   Before, it sat underneath the settings button and only opened if you happened
   to hit the few pixels that were not covered.
2. **Add a café or a twisty road to your own route, with no ride started.** Tap
   a café or highlight marker on the map and choose to route via it. It should
   plan a route. It used to refuse with "Only the ride leader can replace the
   group route" even though there was no ride and no leader.
3. **Import a large GPX.** Use one of the Mid-Wales day-run files. The track
   should be a line you can follow when zoomed out rather than a solid mass of
   yellow dots, and the distance should match the ride rather than roughly
   double it. Check the waypoint count on the review screen looks like the stops
   actually placed, not thousands.
4. **Losing your location in free roam.** Leave the app on the map, switch to
   another app for a few minutes, then come back. Your position should return
   without quitting, and destination search should work. If the position does
   not come back, a **Show my location** button should now be there — previously
   there was nothing at all.
5. **A GPX another app sent you** (iOS). If a `.gpx` file was previously greyed
   out and unselectable in the file picker, try it again.

### Fixed

- The discovery-layer menu was underneath the settings button and could only be
  opened by accident.
- The icons above the map overlapped each other.
- Adding a destination from the discovery layers in free roam failed with a
  leadership rule that did not apply, and showed a raw error type to the rider.
- A GPX from MyRoute-app turned the calculated shape of the road into thousands
  of yellow waypoint markers, and drew the same ride twice.
- Free roam could lose your location with no way back except restarting.
- iOS now recognises a `.gpx` file that arrived without a file type.

### Known limitations

- **Turning an imported GPX into turn-by-turn directions still fails.** The
  routing service accepts far fewer trace points than the app sends, so
  **Generate navigable route** returns an error. Following the imported line
  itself works normally. You may now *see* that error where the option was
  previously not offered at all — that is expected, and the underlying fault is
  tracked as #575.
- The discovery layers still do not appear on the route review screen (#578).
- Choosing a route inside a created ride still differs from choosing one in free
  roam, and leaving a ride before it starts still needs the ride menu (#579).
- The location recovery and the iOS file-type change could not be reproduced in
  a simulator; both need judging on a real phone, which is what this build is
  for.

## iOS build 56 / Android build 56 — 13 August 2026

This build makes it easier to join a group after preparing a solo ride and
improves the spoken-guidance voice controls and measurement wording.

### What to test

1. **Voice preview.** Open Settings, choose a navigation voice, and confirm the
   newly selected voice immediately says: “In 2 miles, at the roundabout, turn
   right.” Try this once with spoken guidance disabled as well; the preview
   should still play, while ordinary ride prompts remain disabled.
2. **Spoken distances.** Follow a route with voice guidance and listen to a few
   distance prompts. Abbreviations such as `yd`, `mi`, `ft`, `m`, `km`, `mph`
   and `km/h` should be spoken as natural words rather than read as letters or
   mispronounced. The visual map labels should remain compact abbreviations.
3. **Join a group from the map.** Prepare a solo ride but do not start it. A
   labelled **Join group** button should sit beside **Start ride**. Tap it and
   join using a six-digit code, paste or invitation scan. The empty solo session
   should be replaced rather than left behind.
4. **Button visibility.** The new **Join group** button should not appear once a
   ride has started, while following another leader, or in an existing group
   lobby.

### Fixed

- Selecting an installed navigation voice now saves it and plays a realistic
  navigation preview immediately.
- The final speech boundary expands common route and speed units into natural
  singular or plural wording without corrupting place names such as “Lloyd” or
  road names such as “M4”.
- An unstarted solo ride now exposes the existing group-code, paste and invite
  scan flow directly beside the primary start action.
- Switching to a group cleans up the unused solo session before opening the join
  flow.

### Known limitations

- The automated tests prove the selected voice and expanded speech reach the
  text-to-speech engine, but the actual sound and pronunciation still depend on
  the voices installed by iOS or Android and need listening checks on each
  device.
- The two-button layout is verified at a 375-point phone width and still needs a
  quick usability check on the physical phones used for rides.

## iOS build 55 / Android build 55 — 13 August 2026

This build simplifies the main navigation, makes both daytime map designs
available, adds a proper library for saved rides, and introduces an optional
private heatmap of roads ridden on this phone.

### What to test

1. **Bottom navigation.** Settings should now be a bottom tab. Alerts should no
   longer have their own tab; open Ride and confirm the alert actions remain
   available there.
2. **Daytime maps.** In Settings, switch the daytime map between **Restrained**
   and **Original**. Check the home map, route review and an active ride, then
   restart the app and confirm the chosen style is retained.
3. **Ride library.** Open **More → Ride library**, scroll through recorded
   routes and previous rides, and check the approximate start-to-finish labels
   (for example, “Kingswood to Chippenham”). Open an older ride and confirm its
   details and export actions are still available.
4. **Personal heatmap.** Open the map layers menu and enable **Personal rides
   heatmap**. It should be off by default, show only tracks actually travelled
   in completed rides, sit beneath the current route, and make repeatedly
   ridden roads more prominent. Disable it and confirm it disappears.

### Fixed

- Replaced the Alerts bottom tab with Settings and moved alert access into Ride.
- Added one scrollable Ride library for recorded routes and previous rides.
- Added offline approximate start and finish place names without uploading ride
  endpoints to a reverse-geocoding service.
- Restored the original OpenFreeMap daytime design as a saved alternative to
  the newer restrained design.
- Added an opt-in personal ride heatmap that is calculated and stored entirely
  on the phone from completed travelled tracks; planned routes are excluded.

### Known limitations

- Place names are approximate and currently use a bundled Great Britain
  settlement index; routes outside its coverage use neutral wording.
- The personal heatmap needs completed rides in the on-device archive and still
  needs visual confirmation on physical iOS and Android devices.
- The global heatmap is not in this build. Its privacy model is designed and
  ticketed, but contribution, aggregation and web-planner work remain disabled
  until their privacy and release gates are met.

## iOS build 54 / Android build 54 — 13 August 2026

This build adds the route-review fixes found while replaying ride 392725 and
finishes several pieces that can be checked without another road test.

### What to test

1. **Ride a previous ride in reverse.** Open a cleaned recorded track, reverse
   it and choose Ride again. The full track should remain visible and produce a
   valid route even if the recording ends with a very short GPS fragment.
2. **Review a previous ride.** The map should frame the complete track and show
   green Start, red Finish and direction arrows clearly enough to tell which
   way it was ridden.
3. **Reshape a route.** Use the new plus and minus controls to zoom in for a
   precise drag and back out to review the whole change.
4. **Use the light map.** It should retain the dark map's restrained road-first
   appearance, labels and one-way information without bringing back noisy POIs.
5. **Watch the turn countdown.** The displayed distance should count down
   smoothly while spoken prompts continue to use the real measured distance.
6. **CarPlay layout.** Directions stay at the upper left, the speed/limit pair
   stays at the upper right, and the overview mini-map has a visible edge.

### Fixed

- Reversing a cleaned previous ride no longer treats an isolated final GPS fix
  as the route and then fails to build directions.
- Archived rides auto-frame the drawable track and show explicit start, finish
  and travel-direction cues.
- Route reshaping now has explicit, bounded zoom controls.
- The light basemap now matches the dark basemap's restrained visual hierarchy.
- The initial speed-limit observation is deferred until after the first frame,
  avoiding a `setState`-during-build exception.
- Turn distance presentation interpolates between real measurements rather than
  stepping once per location update.
- CarPlay start attempts now leave enough diagnostic evidence to distinguish a
  swallowed tap from the route-choice dialog and other safety gates.
- CarPlay's speed pair and overview mini-map have fixed, testable layout bounds.

### Known limitations

- Previous-ride, zoom and light-map changes were verified with ride 392725 in
  the iOS Simulator and automated tests; physical iOS and Android precision is
  still being tracked separately.
- Smooth countdown behaviour still needs an on-road check.
- The phone-start diagnostic and final CarPlay layout still require a physical
  CarPlay-connected ride before their field tickets can close.

## iOS build 53 / Android build 53 — 12 August 2026

This build follows ride 392725. The diagnostic trace explained two reports that
looked like missing roundabouts: New Cheltenham Road was receiving roundabout
geometry but contradictory wording, while the Siston Common instruction was
being replaced by a reroute before the rider had cleared the junction.

### What to test

1. **New Cheltenham Road double mini-roundabout.** Both close junctions should
   show and say *straight on*. It must not say *slight left* when the symbol says
   straight.
2. **Siston Common after a deviation.** A newly calculated route must not replace
   the current instruction while you are still in, or immediately leaving, a
   junction. Its first instruction should also agree with the direction the bike
   is travelling and must not ask you to backtrack or make a U-turn.
3. **Fixed speed-camera warning.** On an urban approach it should arm about
   30 seconds away rather than a mile away. The compact notice should sit at the
   top without covering the rider marker, and the red border should follow the
   phone's rounded corners.
4. **Spoken-guidance voice.** Choose an installed English voice in Settings,
   restart the app, and confirm the same voice remains selected.
5. **Start a ride.** Rider symbol, motorcycle style, and colour should come from
   the saved profile; the route finder should no longer ask for them.

### Fixed

- Roundabout speech and symbols now share the same left/straight/right bucket,
  including when the router supplies no exit number.
- Rerouting sends the rider's reliable direction of travel to the router,
  rejects a first leg that points the wrong way, and never searches backwards
  along the planned course for a rejoin point.
- A recalculation is announced once per off-route episode.
- A calculated route waits until the rider is clear of the active junction
  before replacing the current guidance.
- Enforcement warning distance targets roughly 30 seconds from current speed,
  bounded from 250 m to 1 km, and stays stable once armed.
- The enforcement notice and border respect the map safe area and rounded
  screen corners.
- Installed English text-to-speech voices can be selected and are persisted.
- Ride creation reuses the saved rider profile instead of asking for appearance
  choices on every ride.

### Known limitations

- The route and warning fixes are verified with the recorded ride, unit/widget
  tests, and iOS/Android simulators. They still need confirmation on the same
  roads with live GPS.
- OpenStreetMap camera coverage is incomplete; no camera shown does not prove a
  road has none.
- Voice availability and naming depend on the voices installed by iOS or
  Android. Removing a selected voice safely falls back to the system default.

## iOS build 46 / Android build 46 — 9 August 2026

Everything in this build came from the 2 and 7 August rides. Nothing here has
been ridden yet — that is what this build is for, and the list below is roughly
in the order it is worth checking.

### What to test

1. **Fixed speed cameras now appear.** They never existed before; the app only
   ever knew about cameras a rider reported. 3,480 permanent cameras from
   OpenStreetMap now draw on the map and raise the same warning about a mile
   out. Check one you know: does the warning come early enough, and does it
   clear once passed? **A camera on a parallel road you are not riding should
   not warn you** — that one matters most.
2. **Roundabout symbols.** The ring should sweep clockwise, and the exit arrow
   should be on the road you actually take.
3. **Mini-roundabouts.** These are now restored from OpenStreetMap wherever the
   map marks one, rather than at two junctions somebody had reviewed by hand. A
   mini-roundabout now says which way to go and **no longer says which exit** —
   see the limitation below.
4. **Ordinary turns should not be announced as sharp.** A 90-degree right is a
   right.
5. **The "have all riders finished?" prompt** is now a small bar in the bottom
   chrome instead of a full-screen dialog. The map and the turn banner stay
   visible. *Not yet* should dismiss it and it should stay dismissed while you
   are still at the destination. *End ride* still asks before ending for
   everyone.
6. **Turn guidance messages.** If a route has no prompts, the wording should now
   tell you *why* — an imported track you can simply follow, versus a route
   whose directions could not be built.
7. **CarPlay stability.** Three more places that could crash the app were
   guarded. Ride history and route preview are the ones to poke at.

### Fixed

- Fixed speed cameras appear on the map and warn, from OpenStreetMap (#382)
- The ride-completion prompt no longer covers the map during the final approach (#380)
- Three further crash routes closed, including one that would crash **every time**
  a saved ride with a single repeated GPS fix was opened (#359)
- An ordinary turn is no longer announced as a sharp one (#302)
- Mini-roundabouts restored wherever OpenStreetMap marks one (#163)
- The roundabout sweep and its exit can no longer disagree (#301)
- A route whose routing failed now says so, instead of reading as if nothing
  were wrong (#303)

### Known limitations

- **A mini-roundabout no longer tells you which exit.** This is deliberate.
  Counting exits needs the bearing of every arm, which the map data does not
  carry; the old wording was only ever right at two hand-measured junctions and
  guessed everywhere else. It now says the direction and stops. Saying less
  truthfully beats saying more wrongly — but say if you miss the count.
- **Camera coverage is not complete.** OpenStreetMap does not list every camera.
  A road with none shown has not been confirmed clear.
- **Average-speed and mobile cameras are patchy.** 210 average-speed camera
  systems are included; mobile sites are largely absent and still depend on
  rider reports.
- The relay was down on the evening of 9 August and has been restored and
  brought up to date. If you rode during that window, group presence and alerts
  would not have worked — that was the server, not this build.

## iOS build 45 / Android build 45 — 7 August 2026

Nine fixes from the 6 August ride report. Most of them need a real ride to
confirm — several are things the app was silently not doing rather than doing
wrongly, so the only way to know they are fixed is to go and look.

### What to test

1. **Spoken turn prompts.** Turn them on in settings and ride a route with
   guidance. They did nothing at all before: the setting saved, was read, and
   had nothing behind it. Prompts should now duck your music rather than stop
   it.
2. **The turn banner.** The distance is now on its own line at roughly twice
   its old size, the way Google Maps and Waze set it. Tell us if it is still
   not readable at a glance at speed — there is a hard limit on how much of
   the screen the chrome may take, and the next move is deciding what comes
   off the band rather than growing it further.
3. **Direction arrows on a planned route.** Load a route and look at it before
   starting. Arrows along the line should show which way round it goes. They
   have never been there before a ride started, only on the part already
   ridden.
4. **A solo ride.** Start one and open the roster and the leave/end action.
   Nothing should mention a group, other riders, or ending the ride "for
   everyone" — there is nobody else.
5. **Roundabouts.** The symbol now carries an arrowhead on the ring showing
   which way round you go. **If a roundabout instruction is wrong, please open
   the turn detail and copy the readout** — it now includes the exit number,
   both bearings and the straight band, which is what says whether the exit
   count, the measured turn or the threshold is at fault.
6. **Sharing a ride recap image.** It could previously wait for ever for a map
   that never arrived. It now gives up after 12 seconds and sends the route
   outline with the reason on screen.
7. **Markers at forks.** A fork the route rides straight through now earns a
   suggested marker. That is the junction where a following rider is most
   likely to take the wrong branch.

### Fixed

- Spoken guidance was never connected to anything; turning it on now speaks.
- The turn banner distance was too small to glance at.
- The planned route carried no direction-of-travel arrows.
- Solo rides warned about the Tail End Charlie and about ending the ride for
  everyone.
- A roundabout symbol did not say which way round the ring you travel, so a
  right turn read as anticlockwise. The arc was always correct.
- A roundabout turn detail reported bearings the app had not used, so a
  captured report could not explain the instruction it gave.
- A recap export could block indefinitely on a basemap that never loaded.
- A fork ridden straight through was never suggested as a marker position.
- An invalid camera position could crash the app through MapLibre. This is one
  of two distinct CarPlay-era crashes; the other is not fixed.

### Known limitations

- **CarPlay still has an open crash.** Two separate faults are identified. This
  build stops one of them being fatal. If the app dies with CarPlay connected,
  please plug the phone into a Mac afterwards so the crash log syncs, or send
  the entry from **Settings → Privacy & Security → Analytics & Improvements →
  Analytics Data**.
- Roundabout exit numbering is still wrong at the Tenniscourt Road roundabout
  and at the Syston Common double mini-roundabout. Captures from those two
  junctions are what will fix them.
- No light basemap, no marker editor on the map, and no Siri or music control
  yet. All are open and none is started.

## iOS build 42 / Android build 42 — 4 August 2026

### What to test

1. Start or join a ride and use the bottom **Ride** tab. The common ride
   actions should be visible there without opening a separate hamburger menu.
2. Open the **Alerts** tab. It should focus on road alerts, rerouting and riders
   who actually need attention; routine location status and technical provider
   details should no longer crowd this screen.
3. Check that the less common contact and sharing actions are still available
   by expanding **Contact and sharing** on the Ride page.

### Fixed

- Removed the remaining Ride actions hamburger menu from the live map and
  dashboard.
- Consolidated ride controls into the Ride page and simplified the former
  Safety menu into an actionable Alerts screen.

## iOS build 41 / Android build 40 — 3 August 2026

The newest section is always first, so this is the one to read. Everything in
the iOS build 40 section below is also in this build — and so is the 30 July
section, which build 40 already carried despite still being headed
"unreleased".

This one is mostly the 2 August ride feedback. Several entries are **things to
send us** rather than things to confirm: two faults could not be diagnosed from
the reports we had, so the app now captures the missing data itself.

### What to test

1. **Ride solo for over half an hour with no route set, then end it.** Two
   things to watch, and both matter:
   - Does your own trail stay on the map for the whole ride? It used to be
     dropped after about 2 km, whatever the length of the ride.
   - Afterwards, is the ride in **Previous rides** with its whole track? If it
     is missing and you did *not* see a "This ride was not saved" notice, say
     so — that is the half we have not explained yet.
2. **Plan a route with "avoid motorways" or a twisty preference, then ride it.**
   Turns should now be announced. Routes planned with any of those preferences
   previously arrived with **no turn instructions at all**, which is why
   navigation "sometimes worked and sometimes didn't". This is the single most
   worthwhile thing to confirm in this build.
3. **Choose Initials as your rider symbol.** They should fill the coloured
   circle, and should look the same on the map as they did in the picker you
   chose them from. On the live map they were about a quarter smaller than the
   preview promised.
4. **If a turn is announced wrongly, send us the turn.** Open the ride menu →
   **All turns**, tap the turn that was wrong, and press **Copy turn detail**.
   Paste it into the group. That readout is what tells us whether the router got
   it wrong or we did — we have two open reports we cannot progress without it:
   a 90-degree right called a sharp right, and a roundabout icon that looked
   like the wrong way round.
5. **If the map shows no roads, photograph it.** The map now says *why* when its
   background is missing — "NO MAP BACKGROUND", "NO MAP DATA" or "MAP DID NOT
   LOAD", each a different fault, and tappable for a sentence. If there is no
   badge at all, the map is working and you are somewhere genuinely empty.
   Either way the screenshot now tells us which.
6. **Share a ride recap.** The header used to clip to "TAIL END CHA…" on every
   recap anyone shared. It should read in full.
7. **Before setting off, look at the map.** You should see **your own** position
   with no route set — previously there was no way to get it — and riders who
   have joined should appear before the ride starts, not only once it begins.
   Nothing is recorded or shared as a track before **Start ride**; that has not
   changed.
8. **Join a ride by QR using the labelled button.** There is now a **Scan an
   invitation code** action under the ride-code field. The camera icon in the
   field still works; the label is there because the icon alone was invisible
   enough that this feature was reported missing.
9. **Import a GPX track with no turn instructions.** Choose **Generate
   navigable route** while online. The original should appear as a grey dashed
   line behind the proposed blue road route, with confidence and deviation
   figures to review before confirming. Cancel and check that the current route
   did not change; import it again and choose **Follow original line** to prove
   the offline option still works. The original should be in **Saved routes**
   after either choice (#325).
10. **Tap a private ride invitation from WhatsApp and email.** It should open
    Tail End Charlie, show the six-digit ride code and ask before joining. Try
    once from a cold launch and once while the app is already open. If another
    ride is active, it must keep that ride rather than silently replacing it.
    Uninstalling the app should make the same link open a help/install page;
    copying the whole link into **Paste** must still join (#275).
11. **Prepare a ride on the phone, then connect to CarPlay.** The CarPlay map
    should use the same style, route, riders and forward-looking framing as the
    phone, with a smaller group overview, turn/marker symbols, speed and mapped
    speed limit. As leader, use **Start prepared ride** and confirm both the
    route summary and any no-TEC warning. Create/join and first-time permission
    prompts deliberately remain on the phone (#295, #328).
12. **From the CarPlay map, report a hazard and open SOS.** Report should use
    the current location and SOS must require confirmation. Check the launcher
    and map controls on a right-hand-drive display if one is available (#295).

### Fixed and new

- A long ride no longer loses the track drawn behind you. The limit was 120
  points — roughly 2.4 km whatever the ride's length — which also silently
  undid the leader-trail fix in the last build (#299).
- Routes planned with a motorcycle preference now carry turn instructions. The
  motorcycle router does return them; they were being discarded (#303).
- The ride map says why it has no roads on it, instead of an empty background
  that looks the same as open countryside (#281).
- Rider initials are sized by one rule everywhere, so the map, the group
  overview and the symbol picker agree (#259).
- Any turn can be opened in **All turns** to see what the router said about it,
  and copied for a report (#302, #301).
- A ride that cannot be saved says so, and the 24-hour cleanup no longer deletes
  a ride it failed to save (#299).
- The recap header no longer clips (#308).
- Your own position appears on the map before the ride starts, with no route
  needed, and riders who have joined are visible before it starts too (#300).
- QR joining, and the ride's four navigation destinations, now have words rather
  than bare icons (#306).
- Ending a ride asks the same question wherever you do it, and a leader who is
  currently marking a junction can end the ride again — that had silently done
  nothing (#306).
- A rider can leave the watcher-link sheet (#304).
- The mini-map frames riders it cannot place yet (#172).
- A route with no turn prompts says that, rather than claiming the route failed
  (#303).
- An imported track with no turn prompts can now be road-matched into a
  navigable candidate. The original is preserved, uncertain matches are
  rejected, and the candidate is compared against it before confirmation
  (#325).
- Ride invitations are now tappable Universal/App Links. The private resolve
  token stays in the URL fragment, the established paste invitation still
  works, and the app refuses to replace an active ride silently (#275).
- The riding surface now has labelled Map, Details and Safety navigation plus
  one shared **Ride actions** sheet; leaders can end for everyone from the same
  leave/end action (#306).
- CarPlay now uses the ride map style and route framing, rider symbols, group
  mini-map, navigation symbols, speed/speed limit, report/SOS actions and a
  leader-only **Start prepared ride** action. Ride creation, joining, route
  choice and first permissions remain phone setup (#295, #328).

### Known limitations

- **Two faults in this build are instrumented, not fixed.** The wrongly
  announced turn (#302) and the roundabout icon (#301) both need the turn detail
  from item 4 before they can be worked on. Nothing about them has changed
  except that they can now be reported properly.
- **The blank ride map (#281) is still not explained.** The badge tells us which
  of four faults it is; it does not stop it happening.
- **The second half of the lost-ride report (#299) is unexplained.** The saved
  track is proven complete by test, and the archive now says so when it fails.
  If a ride still goes missing, that is new information.
- CarPlay still needs a signed physical iPhone/head-unit run before it can be
  called release-validated. The installed iOS 26.5 simulator filters unsigned
  restricted-entitlement builds from its CarPlay catalogue (#295, #328).

## iOS build 40 — 1.0.1 — 2 August 2026

Everything in the 30 July section below is also in this build; it was never
released on its own.

### What to test

1. **Ride for longer than 40 minutes and look at the leader's trail.** It used
   to vanish after roughly that long. It should now stay for the whole ride.
   This is the one most worth confirming - it came straight from tester
   feedback and has only been proven by test, not on a bike.
2. **Join a ride with no signal at all.** The leader opens **Scan to join** and
   shows the QR code; another rider scans it. Both phones can be in aeroplane
   mode. Everything needed to join is inside the code, so no network is used.
   The six-digit code still needs signal - that has not changed.
3. **Listen to the turn prompts.** Turn instructions are now spoken. They should
   duck music rather than stop it, and should not speak when no ride is running.
4. **Watch the speed readout.** It used to flicker on and off while riding.
   It should now stay steady while you are moving and disappear only when
   position updates genuinely stop.
5. **Leave the map mid-ride and come back.** The started ride must still be
   there, and alerts you already dismissed must stay dismissed.
6. **End a ride as leader.** Everyone else should be told who ended it.
7. **Check the map in a patchy-signal area you have ridden before.** Tiles are
   now kept, so somewhere you have already been should still draw. Somewhere
   genuinely new with no signal will still be blank.

### Fixed and new

- The leader's trail is no longer discarded partway through a ride. The limit
  that caused it was raised from 600 points to about 27 hours' worth, which was
  only safe because the map work behind it no longer gets slower as a ride goes
  on (#280).
- A ride can now be formed offline by scanning a QR code. The invitation carries
  its own credentials, so nothing is fetched (#279).
- Turn instructions are spoken aloud, mixed with and ducking other audio rather
  than interrupting it (#286).
- The live speed readout no longer flickers. It now hides when position updates
  stop rather than after a fixed delay, which also keeps a parked bike from
  showing a stale speed (#285).
- Leaving the map no longer loses a started ride or resurrects alerts you had
  already cleared (#282).
- Everyone is told who ended a ride, instead of it just disappearing (#283).
- Exactly one rider can hold the lead at a time; the most recent claim wins
  (#284).
- Map tiles are kept between sessions by default, so a revisited area still
  draws without signal and a route corridor can be downloaded before setting
  off (#274, #281).

### Known limitations

- **The watcher map needs no action from you, but it is new.** The relay now
  serves a map for watcher links, so a safety contact should see roads rather
  than a pair of coordinates. If they still see coordinates, say so.
- Caching only helps where you have already been. A first visit to a dead spot
  still has nothing to draw; download the route before you leave if you expect
  no signal.
- The mobile ride map showing no roads while you *do* have signal (#281) is not
  fixed. If it happens, note where you were.
- CarPlay opens on an unzoomed map of the whole UK with nothing on it (#295).
  Known, not yet worked on.
- The trail fix, spoken prompts and offline QR joining have not been confirmed
  on a physical bike - that is what this build is for.

## Next Android and iOS tester build — unreleased — 30 July 2026

### What to test

1. **Start each ride type.** Create a solo ride, a
   **Second-bike drop-off** group, and a **Keep-together group**. Solo must have
   no join code or group radios. Keep-together must retain the roster and group
   messages without marker prompts or marker statistics.
2. **Open both watcher-link types.** From any solo or group ride, create
   **Just me** and confirm the browser sees only that phone's last-known
   position and status. As the group leader, create **Whole group**, confirm
   that you have told the group, and check that the browser lists the current
   roster, each rider's coloured last-known position and freshness, and the
   planned route. Pan the map, then use **Re-centre ride**. Neither watcher
   should appear in the rider list.
3. **Check initials on both maps.** Choose two-letter initials and confirm they
   fill the rider circle horizontally rather than appearing as a tiny vertical
   stack on Android or iOS.
4. **Export a ride recap.** Pan and zoom the recap map, then share it in both
   light and dark modes. The PNG must contain the framed vector basemap, route
   and attribution.
5. **Start away from the route.** A route more than 250 m away should offer
   **Navigate to start** instead of saying turn guidance is unavailable. Once
   the planned route is reached, guidance should continue on the main route.
6. **Reshape on Android.** Drag the route and purple shaping handle at display
   scaling above 1×. It should behave the same as iOS.
7. **Review the waiting screen.** Before Start, SOS, Leave, Report, speed and
   turn guidance must stay hidden; the participant list is one compact line.

### Fixed and new

- Recap export now uses a capture-safe Flutter vector map instead of a native
  platform view that disappeared from the PNG (#157).
- Initials no longer wrap inside Android MapLibre and occupy 94% of the rider
  badge (#259).
- Android route reshaping converts Flutter gesture points to native-view pixels
  before hit-testing (#242).
- Distant routes offer a routed leg to the planned start, while all
  riding-time guidance and controls remain hidden before Start (#254, #262).
- Ride creation now distinguishes solo, second-bike drop-off and keep-together
  coordination. Solo skips participant transports but retains the private
  watcher link; keep-together disables marker behaviour without losing group
  communication (#261).
- A group leader can create a distinct, revocable whole-group watcher link
  after confirming the group has been told. The read-only browser shows a
  bounded live roster, per-rider freshness, last-known positions and planned
  route, without joining the ride or receiving ride credentials (#263).

### Known validation still needed

- Recap PNG export, Android route reshaping, initials and route-to-start
  handover still need physical-device confirmation in the next tester build.
- Group watcher creation, leader handover, expiry/revocation and mixed
  fresh/delayed/offline rider states need multi-phone validation.
- The previously reported long-ride lag was materially improved in build 37;
  keep reporting the phone model and elapsed ride time if it returns.

## Android and iOS build 35 — 1.0.1 — 29 July 2026

This build supersedes build 34 on Google Play closed testing (`alpha`) and
TestFlight. It combines the latest tester-feedback fixes with the new rider
symbol choices.

### What to test

1. **Choose your rider symbol.** In Settings, switch between a bike, your
   initials and an emoji. Confirm the same symbol and rider colour appear in the
   roster, main map and group mini-map on both phones.
2. **Follow a long route.** Use a route whose next turn is more than 5 km away.
   Guidance should remain visible. Losing GPS or going off route should show an
   explicit status instead of leaving an empty guidance area.
3. **Put the app in the background.** Start sharing, lock the phone or put
   another navigation app in front for at least 20 minutes, then compare with a
   second phone. If location stops, the recorded ride must show a gap rather
   than drawing and counting a false straight line.
4. **Assign a TEC.** After one rider has selected TEC, ask another rider to take
   the role. Once accepted, every roster, map, gap and rejoin surface should
   treat only the accepted rider as the effective TEC.
5. **Move around the live map.** Pan and pinch on both platforms, then use
   **Follow me** to recover. A widely separated group should fit inside the
   mini-map with a meaningful scale.
6. **Start without a route.** A follower can dismiss the waiting prompt, and it
   must not return after the leader starts the route-less ride.
7. **Reuse a previous ride.** Open a previous ride, choose **Ride again**, pick
   the planned or recorded route, and try the reverse option. On a small iPhone,
   every route-source action must remain reachable.
8. **Dismiss a quick message.** Open and close the ride menu afterwards; the
   cleared interrupt or receipt must not appear again.

### Fixed and new

- Rider symbols can be a bike, initials or an emoji, with a safe bike fallback
  when talking to an older build (#253).
- Turn guidance no longer disappears when the next manoeuvre is more than 5 km
  away, and every non-active state is explained (#254).
- iOS explicitly asks for the background location access required for another
  navigation app to stay in front; missing recording periods are left blank
  and excluded from distance (#205).
- An accepted leader assignment becomes the one effective TEC everywhere
  (#128).
- Dismissed quick-message overlays survive leaving and returning to the map
  (#178).
- Map gesture handoff, Follow me diagnostics and wide-area mini-map framing are
  hardened across iOS and Android (#141, #172, #248).
- Route-less followers can continue without a blocking prompt (#249).
- Rider identity colours stay consistent between roster and map (#250).
- Previous rides have a direct **Ride again** path (#251).
- The iOS route chooser scrolls safely on compact screens (#252).

### Known validation still needed

- Please include the phone model, operating system, build number and whether
  the problem happened over internet or nearby transport in every report.
- Background location, multi-device TEC handover, mixed-version rider symbols,
  map gestures and a full off-route ride still require physical-device results.
- CarPlay navigation is not in build 35. Apple approved the navigation
  entitlement under Case-ID 21286533; implementation and signed Profile
  validation are complete on the development branch. Apple's simulator does
  not launch restricted-entitlement builds, so physical CarPlay/head-unit
  validation remains required before claiming production support.

## Android and iOS build 34 — 1.0.1 — 29 July 2026

This build supersedes build 33 and contains the latest tester-feedback fixes on
both Google Play closed testing (`alpha`) and TestFlight.

### What to test

1. **Reshape a route in the app.** On the route review map, enter
   **Reshape**, drag the route onto another road, move the purple shaping
   handle, then try Undo and Remove. Cancelling must keep the current route;
   Confirm must apply the new road route without turning shaping points into
   named stops.
2. **Review marker positions on the web and in the app.** Yellow dots are
   likely turn markers, red positions need a safety review and teal positions
   are muster points. Reject one and add a missed junction, then transfer the
   route by GPX or private app code and check that both decisions survive.
3. **Finish a group ride.** Reaching the destination must show the leader why
   the group looks finished and ask before ending. Choose **Continue ride**
   once, then leave and re-enter the destination area to confirm the prompt
   re-arms. Finally choose **End for everyone**.
4. **Leave as the leader.** The map-level Leave button now offers
   **Leave only** and **End for everyone** directly.
5. **Go off route.** The purple rejoin track must now drive the turn-by-turn
   directions as well as drawing the route.
6. **Review a long route.** Confirm is at the top; marker positions, route
   points and the full turn list no longer have to be scrolled past.
7. **Frame route and previous-ride maps.** Pan and zoom should respond
   reliably, the whole ride should initially fit, and **Fit whole route/ride**
   should restore the frame. Sharing a ride must preserve the frame you chose.

### Fixed

- Off-course reroutes now provide directions instead of only a line (#162).
- Long route confirmation no longer sits below every turn and waypoint (#240).
- Route preview, sharing and previous-ride maps frame the whole journey and
  accept touch gestures reliably (#239).
- A leader can end the ride for everyone from the normal Leave action (#241).
- Route reshaping now works in the app without creating extra stops (#242).
- Marker-plan review is available on the web and survives GPX/app-code handoff
  (#243).
- Arrival detection no longer silently ends a ride; the leader sees the
  evidence and chooses whether to continue or end for everyone (#244).

### Known validation still needed

- Please report the phone model and build number when testing route dragging.
- The end/reopen flow still needs results from two physical phones, especially
  whether both phones resume within 24 hours without changing the ride code.

## Android build 31 — 1.0.1 — 28 July 2026

Almost everything here came from what you told us on 27 July. Where a fix is
named after a ticket, that ticket is your report.

### What to test

1. **End of a ride.** It used to lock up. The cause was the app
   re-checking the signature on every event in the ride, every time anything
   changed. Ending a long ride is now around 0.8 s on the phone we profiled.
2. **Leading a ride.** The leader was being judged against their *own* trail
   instead of the planned route, so the person at the front got told they were
   off-route while leading it. Please lead one and confirm it stays quiet.
3. **Distance to the TEC.** It now says which way the gap is going — TEC
   stopped, Closing, Holding, or Opening — with an arrow as well as the word.
   The number alone never told you whether to ease off.
4. **The group mini map.** It now frames every rider and scales itself, with a
   scale bar on both Android and iOS. A glance should tell you whether the group
   is spread over half a mile or twenty.
5. **Riding a route you already rode.** Pick a previous ride or a recorded
   track directly instead of exporting a GPX and importing it back. Recorded
   tracks are offered cleaned, with the raw one still there if you want it.
6. **Cameras and police on the map.** Reports now appear as symbols, and only
   when they are ahead of you, not behind.

### Fixed

- Ending a ride no longer makes the app unresponsive (#165).
- The leader is judged against the planned route, not their own trail (#162).
- Cancelling a ride stop no longer asks repeatedly about the same one (#178).
- "Ride ended" says the ride is **filed**, not removed from your phone (#156).
- A MyRouteApp export is no longer counted and drawn twice — the file describes
  the same ride as both a route and a track (#180).
- The emergency text no longer claims a recipient it does not have, and now
  sends your position (#173).
- A ride that loses its leader now offers somebody the role (#176).
- The dashboard gives one answer about connectivity instead of three (#174).
- An interrupting alert no longer covers SOS and Leave (#124).
- The emergency actions sheet fits a phone held sideways (#193).
- The speed-limit sign now buffers the next kilometre, keeps prefetched answers
  through a signal drop, shows `∞` only for an explicitly unrestricted road,
  and never returns to a spinner after its first answer (#164).
- From a BS15 1UJ start, both New Cheltenham Road mini-roundabouts now appear as
  separate 2nd-exit instructions 42 m apart, even though both routing engines
  omit them (#163).
- The recap image has real map tiles and a light/dark toggle (#157).
- Marking positions the group rides straight past are no longer suggested, and
  you can reject one and have it stay rejected (#179).

### New

- Share your own number with the leader and TEC, or as leader/TEC with the
  ride, so people can call or message you from the rider list instead of
  digging through contacts. Entirely optional, both directions, and it is
  deleted at the end of the ride unless it was dialled (#188).
- Rate a catalogued road after riding it — one tap, optional, and anonymous.
  The relay stores answers as counts only, with no way to tell whose was
  whose (#159).
- Ask for routes that avoid motorways or prefer twisty roads, and see speed
  limit and enforcement facts when picking a discovery road (#182, #160).
- Position is reported on distance travelled rather than on a timer, with a
  separate keep-alive (#166).
- 37 discovery passes now carry checked, cited descriptions instead of
  generated ones (#158).

### Also fixed — from what you reported on the morning of 28 July

- **The app now keeps recording and sharing your position while it is not on
  screen.** It was foreground-only, so a phone in a pocket or sitting behind
  another navigation app contributed nothing to the group, and its recorded
  trail became a straight line between the last fix before backgrounding and
  the first one after (#205).
- **A loop route no longer ends the ride on its own start line.** Arrival was
  tested against the route's last point alone, so a day tour finishing at the
  hotel it started from counted as arrived the moment it began — one tester's
  Isle of Man tour ended itself about twenty minutes in (#206).
- **The "Ride ended" screen has a way out that gives nothing up.** Filing the
  ride was the only exit, and filing stops your phone waiting for other riders'
  final events (#207).
- **A rejoin no longer fails because a compatibility probe timed out.** The
  probe ran before the ride code was even looked up, so a rider on working 4G
  was told "Ride service compatibility check timed out" and could not get back
  into her own ride (#208).
- **The speed readout no longer holds a number while you are stopped.** A
  stationary phone produces no fixes at all, and the readout was only updated
  when one arrived (#210).
- **An archived ride no longer shows a "Planned route" key when it had no
  planned route** (#211).

### Known limitations — please do not re-report these

- **Speed limits do not prefetch ahead**, and an unrestricted stretch shows no
  infinity symbol yet (#164 stays open for both).
- **The recap image export is not yet confirmed on a real phone** — the file it
  writes has only been checked on a test machine (#157).
- **The new reporting rate is not field-measured.** On a fast A-road it saves
  nothing, and a *stationary* off-route rider may take about 30 s to show as
  off-course rather than about 3 s. We want to know how that feels (#166).
- **Camera and police symbols have not been checked through a visor in
  sunlight.** That is the whole point of them, and no test on a computer can
  tell us (#135).
- **A discovery road sourced only from a directory listing looks identical to
  one whose claim was actually read and checked** (#215).
- **The freeze on the ride map after joining is NOT confirmed fixed.** There is
  no reproduction of it yet. The two unbounded waits on the join and cold-start
  paths that the report points at are now bounded, which is hardening rather
  than a diagnosis. If it happens again please say so straight away, and if you
  can, what you did in the seconds before — that is the missing piece (#209).

## Android build 30 — 1.0.1 — 27 July 2026

Recorded after the fact. These changes were sitting under "Unreleased" when
build 30 went out, but every one of them is present at build 30's commit
(`fc5b699`) — so testers on 30 already have them, and leaving them listed as
pending would have had build 31 claim them a second time.

- Builds now report their real version and build number to the relay instead of
  the hardcoded `1.0.1+22` fallback, so a bug report can be matched to code.
- New **Settings → About & build** screen showing app version, build number,
  distribution track, build date, relay host and last relay sync, with a
  one-tap copy for bug reports.
- Non-blocking "a newer tester build is probably available" prompt on the home
  screen with a direct route to the store page for the track the build was
  released to (TestFlight on iOS). The hard **App update required** gate is
  unchanged.
- Android closed testers: the update button now opens the closed-testing opt-in
  page, `https://play.google.com/apps/testing/app.tailendcharlie`, instead of the
  public store listing - which does not offer the app to a closed tester who has
  not opted in - and **About & build** reports `Play closed testing (alpha)`
  rather than `Play internal testing`.
- New tester guide: [tester-update-guide.md](./tester-update-guide.md), now
  written for the closed track, with internal testing as a separate section.
- A release that reaches the Android closed track emails the tester group with
  the version, build number, commit, what changed and the opt-in link.

## Unreleased

Changes merged but not yet in a tester build.

_Nothing outstanding: everything on `main` is in build 35._

## Earlier

Before this file existed, tester notes were published as dated documents:

- [23 July 2026](./tester-release-2026-07-23.md)

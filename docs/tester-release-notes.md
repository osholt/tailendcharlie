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

_Nothing outstanding: everything on `main` is in build 34._

## Earlier

Before this file existed, tester notes were published as dated documents:

- [23 July 2026](./tester-release-2026-07-23.md)

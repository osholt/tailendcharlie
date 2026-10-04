# Speed-limit audit

Finds mapped speed limits that a ride says may be out of date (#852).

The speed-limit sign in the app is not an inference. It reads the OpenStreetMap
`maxspeed` tag through Valhalla, so a road mapped 20 mph shows 20 mph even where
the sign now says 30. Welsh councils have been returning roads from the 2023 default
20 mph to 30 mph, and the map has not always followed. A ride that went along such a
road at a steady 34 mph, past a way mapped 20, is the evidence.

```bash
python3 tools/speed_limit_audit/speed_limit_audit.py ride.gpx
python3 tools/speed_limit_audit/speed_limit_audit.py ride.gpx --json report.json
python3 tools/speed_limit_audit/speed_limit_audit.py ride.gpx --dry-run   # asks nothing
```

Python 3.9 or newer, standard library only. The ride must be a recorded track with
times; a planned route has no speed.

## What it does

1. Works out the rider's **sustained** speed at each fix over a 20 s window, as
   distance along the track over elapsed time, so a burst past a lorry is not a pace
   and a bend is not a slowdown.
2. Asks Valhalla `trace_attributes` what limit the map records along the track, in
   chunks of at most 300 points and no faster than one request every 1.1 s. The
   instance is shared and public; the tool refuses an interval under a second and
   says up front how many requests a ride needs.
3. Reports each **stretch** where the sustained speed beat the mapped limit by at
   least 7 mph for at least 150 m: the OSM way ids, the road's reference or name, the
   mapped limit, the median speed, how far it went, and where it started and ended.

```text
1. B4235 - mapped 20 mph, median 34 mph (+14), 622 m
   way/486644403, way/938784787
   https://www.openstreetmap.org/way/486644403
   https://www.openstreetmap.org/way/938784787
   from 51.69772,-2.83158 to 51.69256,-2.83048 at 2026-01-01T12:00:38Z (secondary)
```

A stretch ends where the limit changes, the recording breaks, or the rider drops back
under the threshold, so each way is judged against its own limit. Fixes on a road with
no mapped limit are counted and never judged.

Options: `--threshold-mph` (7), `--min-distance-m` (150), `--window-s` (20),
`--interval-s` (1.1, not below 1), `--json PATH`, `--url`, `--dry-run`.

## What a result means

A line is a **lead, not a finding**. A rider can exceed a limit that is correctly
mapped, and the map-matching is Valhalla's best guess at where the fixes were. So:

1. Check the sign - a photograph, or street-level imagery of the road.
2. If the map is wrong, edit OpenStreetMap on the way, with `maxspeed=30 mph` (or
   whatever the sign says), `source:maxspeed=sign` and `check_date:maxspeed`. Recording
   that a person read the sign is what lets the next mapper trust it.
3. If the map is right, the ride was fast. Nothing to do.

The tool edits nothing. It writes only the file `--json` names.

## Privacy

The track goes to the Valhalla service named by `--url` (the public instance by
default) and nowhere else. The report holds the start and end of each reported stretch
and no other part of the track, but those are still places the rider was: do not paste
a report in public without looking. Never commit a GPX, a report or a diagnostics log.

## Tests

```bash
python3 -m unittest discover -s tools/speed_limit_audit/tests -v
```

No test reaches the network. The recorded Valhalla answer in `tests/fixtures/` is for
`synthetic_ride.gpx`, a ride **generated** along public road geometry at invented
speeds: no fixture is a recording of any rider.

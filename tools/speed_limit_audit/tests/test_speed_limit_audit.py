"""The speed-limit audit (#852).

No test here reaches the network. The Valhalla answer used throughout was recorded
on 4 October 2026 for `fixtures/synthetic_ride.gpx`: a ride *generated* along the
B4235 east of Usk at invented speeds, so that nothing in this directory is a
recording of any rider, let alone of where one starts or ends.
"""

import contextlib
import copy
import io
import json
import math
import pathlib
import re
import sys
import tempfile
import unittest
import urllib.request
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

import speed_limit_audit as audit

FIXTURES = pathlib.Path(__file__).resolve().parent / "fixtures"
RIDE = FIXTURES / "synthetic_ride.gpx"
RECORDED = json.loads((FIXTURES / "trace_attributes_synthetic_ride.json").read_text())

METRES_PER_DEGREE = 111195.0
MPH = 0.44704


def line(count, spacing_metres, *, step_seconds=1.0, start=(51.7, -2.9), t0=1_000_000.0):
    """Fixes heading due east, [spacing_metres] apart and [step_seconds] apart in time."""
    return steps([spacing_metres] * (count - 1), step_seconds=step_seconds, start=start, t0=t0)


def steps(metres, *, step_seconds=1.0, start=(51.7, -2.9), t0=1_000_000.0):
    """Fixes heading due east: the first at [start], then one a second after each step."""
    per_degree = METRES_PER_DEGREE * math.cos(math.radians(start[0]))
    east = [0.0]
    for step in metres:
        east.append(east[-1] + step)
    return [
        audit.TrackPoint(start[0], start[1] + distance / per_degree, t0 + index * step_seconds)
        for index, distance in enumerate(east)
    ]


def intervals(values):
    """The gaps between consecutive values."""
    return [values[index + 1] - values[index] for index in range(len(values) - 1)]


def fixes_of(points, mph, limit, *, segment=0, way=1, names=("B4235",)):
    road = audit.MatchedRoad(
        way_id=way, names=tuple(names), road_class="secondary", limit_mph=limit
    )
    return [audit.Fix(segment, point, mph, road) for point in points]


class NoNetworkTestCase(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(
            urllib.request,
            "urlopen",
            side_effect=AssertionError("a test reached the network"),
        )
        patcher.start()
        self.addCleanup(patcher.stop)


class TimeTest(unittest.TestCase):
    def test_gpx_timestamps_in_the_forms_real_files_use(self):
        base = audit.parse_time("2026-10-04T10:43:38Z")
        self.assertEqual(audit.parse_time("2026-10-04T10:43:38.250Z"), base + 0.25)
        self.assertEqual(audit.parse_time("2026-10-04T10:43:38.5"), base + 0.5)
        self.assertEqual(audit.parse_time("2026-10-04T11:43:38+01:00"), base)
        self.assertEqual(audit.parse_time("2026-10-04T05:43:38-0500"), base)
        self.assertEqual(audit.parse_time("2026-10-04 10:43:38Z"), base)

    def test_something_that_is_not_a_time_is_refused(self):
        for text in ("", "yesterday", "2026-10-04", "10:43:38"):
            with self.assertRaises(ValueError, msg=text):
                audit.parse_time(text)


class ReadGpxTest(unittest.TestCase):
    def read(self, text):
        with tempfile.NamedTemporaryFile("w", suffix=".gpx", delete=False) as handle:
            handle.write(text)
        self.addCleanup(pathlib.Path(handle.name).unlink)
        return audit.read_gpx(handle.name)

    GPX11 = (
        '<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1"><trk>'
        '<trkseg><trkpt lat="51.0" lon="-2.0"><time>2026-01-01T12:00:00Z</time></trkpt>'
        '<trkpt lat="51.0001" lon="-2.0"><time>2026-01-01T12:00:01Z</time></trkpt>'
        '<trkpt lat="51.0002" lon="-2.0"/>'
        '<trkpt lat="51.0003" lon="-2.0"><time>2026-01-01T12:00:03Z</time></trkpt></trkseg>'
        '<trkseg><trkpt lat="52.0" lon="-1.0"><time>2026-01-01T13:00:00Z</time></trkpt>'
        '<trkpt lat="52.0001" lon="-1.0"><time>2026-01-01T13:00:01Z</time></trkpt></trkseg>'
        "</trk></gpx>"
    )

    def test_segments_are_kept_apart_and_untimed_fixes_dropped(self):
        segments = self.read(self.GPX11)

        self.assertEqual([len(segment) for segment in segments], [3, 2])
        self.assertEqual(segments[0][0].latitude, 51.0)
        self.assertEqual(segments[1][0].longitude, -1.0)

    def test_gpx_1_0_is_read_too(self):
        segments = self.read(
            self.GPX11.replace(
                "http://www.topografix.com/GPX/1/1", "http://www.topografix.com/GPX/1/0"
            )
        )

        self.assertEqual(len(segments), 2)

    def test_the_synthetic_ride_is_one_timed_segment(self):
        segments = audit.read_gpx(str(RIDE))

        self.assertEqual(len(segments), 1)
        self.assertEqual(len(segments[0]), 112)

    def test_a_planned_route_has_no_speed_to_compare(self):
        with self.assertRaises(audit.AuditError) as caught:
            self.read(
                '<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1"><rte>'
                '<rtept lat="51" lon="-2"/><rtept lat="51.1" lon="-2"/></rte></gpx>'
            )

        self.assertIn("no recorded track", str(caught.exception))

    def test_a_file_that_is_not_gpx_is_reported(self):
        with self.assertRaises(audit.AuditError):
            self.read("this is not xml")
        with self.assertRaises(audit.AuditError):
            audit.read_gpx("/nonexistent/ride.gpx")


class SustainedSpeedTest(unittest.TestCase):
    def test_a_steady_ride_reads_its_own_speed(self):
        points = line(60, 13.4112)  # 13.4112 m/s is 30 mph

        speeds = audit.sustained_speeds_mph(points)

        for speed in speeds:
            self.assertAlmostEqual(speed, 30.0, delta=0.2)

    def test_a_standstill_is_zero_not_missing(self):
        points = line(30, 0.0)

        self.assertTrue(all(speed == 0.0 for speed in audit.sustained_speeds_mph(points)))

    def test_one_fast_second_is_not_a_sustained_speed(self):
        # 20 mph, one second at 40 mph, then 20 mph again.
        points = steps([8.9408] * 30 + [17.8816] + [8.9408] * 30)

        speeds = audit.sustained_speeds_mph(points)

        self.assertLess(max(speed for speed in speeds if speed is not None), 23.0)

    def test_the_window_is_a_window_and_not_a_pair(self):
        # 20 mph, then 40 mph: where they meet the speed is the average of the window.
        points = steps([8.9408] * 39 + [17.8816] * 40)

        speeds = audit.sustained_speeds_mph(points, window_seconds=20)

        self.assertAlmostEqual(speeds[10], 20.0, delta=0.3)
        self.assertGreater(speeds[40], 27.0)
        self.assertLess(speeds[40], 33.0)
        self.assertAlmostEqual(speeds[70], 40.0, delta=0.3)

    def test_a_gap_in_the_recording_is_unknown_not_slow(self):
        points = line(3, 13.4112, step_seconds=60)

        self.assertEqual(audit.sustained_speeds_mph(points, 20), [None, None, None])

    def test_distance_is_along_the_track_so_a_bend_does_not_slow_it(self):
        east = line(20, 13.4112)
        north = [
            audit.TrackPoint(
                east[-1].latitude + (index + 1) * 13.4112 / METRES_PER_DEGREE,
                east[-1].longitude,
                east[-1].time + index + 1,
            )
            for index in range(20)
        ]

        speeds = audit.sustained_speeds_mph(east + north)

        self.assertAlmostEqual(speeds[19], 30.0, delta=0.3)


class ChunkTest(unittest.TestCase):
    def test_no_request_carries_more_than_300_points(self):
        parts = audit.chunks(700)

        self.assertEqual([len(part) for part in parts], [300, 300, 100])
        self.assertEqual(parts[1].start, 300)
        self.assertEqual(parts[-1].stop, 700)

    def test_a_short_ride_is_one_request_and_nothing_is_none(self):
        self.assertEqual(len(audit.chunks(300)), 1)
        self.assertEqual(len(audit.chunks(301)), 2)
        self.assertEqual(audit.chunks(0), [])


class LimitTest(unittest.TestCase):
    def test_valhalla_kilometres_per_hour_become_whole_mph(self):
        for kilometres, mph in ((32, 20), (48, 30), (64, 40), (80, 50), (97, 60), (113, 70)):
            self.assertEqual(audit.limit_mph(kilometres), mph)

    def test_a_limit_that_is_not_a_number_is_no_limit(self):
        for value in (None, "unlimited", 0, -1, True, [], {}):
            self.assertIsNone(audit.limit_mph(value), msg=repr(value))


class FakeService:
    """A transport that answers from a recording and keeps time on a fake clock."""

    def __init__(self, answers, *, request_seconds=0.2):
        self.answers = list(answers)
        self.now = 100.0
        self.request_seconds = request_seconds
        self.sleeps = []
        self.starts = []
        self.requests = []
        self.warnings = []

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds

    def post(self, url, body, headers, timeout):
        self.starts.append(self.now)
        self.requests.append((url, body, headers, timeout))
        self.now += self.request_seconds
        answer = self.answers.pop(0) if len(self.answers) > 1 else self.answers[0]
        if isinstance(answer, Exception):
            raise answer
        return answer

    def trace(self, **overrides):
        return audit.ValhallaTrace(
            "https://valhalla.example.test/trace_attributes",
            post=self.post,
            sleep=self.sleep,
            clock=self.clock,
            warn=self.warnings.append,
            **overrides,
        )


def service(*answers, **kwargs):
    return FakeService(answers, **kwargs)


def answer_for(count, *, limit_kmh=32, way=11, names=("B4235",), kind="matched"):
    """A minimal trace_attributes answer: one edge, every fix on it."""
    return (
        200,
        {
            "edges": [
                {
                    "speed_limit": limit_kmh,
                    "way_id": way,
                    "names": list(names),
                    "road_class": "secondary",
                }
            ],
            "matched_points": [{"type": kind, "edge_index": 0}] * count,
        },
    )


class TraceTest(NoNetworkTestCase):
    def test_a_request_asks_for_the_limit_and_nothing_about_the_rider(self):
        fake = service(answer_for(10))
        points = line(10, 10)

        fake.trace().match(points)

        url, body, headers, _ = fake.requests[0]
        self.assertEqual(url, "https://valhalla.example.test/trace_attributes")
        self.assertEqual(body["costing"], "motorcycle")
        self.assertEqual(body["shape_match"], "map_snap")
        self.assertEqual(body["filters"]["attributes"], list(audit.REQUESTED_ATTRIBUTES))
        self.assertEqual(len(body["shape"]), 10)
        self.assertEqual(set(body["shape"][0]), {"lat", "lon"})
        self.assertEqual(set(body), {"shape", "costing", "shape_match", "filters"})
        self.assertIn("TailEndCharlie", headers["User-Agent"])

    def test_it_will_not_send_more_points_than_the_service_may_take(self):
        with self.assertRaises(ValueError):
            service(answer_for(301)).trace().match(line(301, 10))

    def test_requests_are_never_closer_than_the_interval(self):
        fake = service(answer_for(5))
        trace = fake.trace()

        for _ in range(4):
            trace.match(line(5, 10))

        gaps = intervals(fake.starts)
        self.assertEqual(len(gaps), 3)
        self.assertTrue(all(gap >= 1.1 - 1e-9 for gap in gaps), gaps)
        self.assertEqual(trace.requests, 4)

    def test_a_slow_answer_does_not_make_the_next_request_wait_longer(self):
        fake = service(answer_for(5), request_seconds=3.0)
        trace = fake.trace()

        trace.match(line(5, 10))
        trace.match(line(5, 10))

        self.assertEqual(fake.sleeps, [], "the answer took longer than the interval")

    def test_the_first_request_does_not_wait(self):
        fake = service(answer_for(5))

        fake.trace().match(line(5, 10))

        self.assertEqual(fake.sleeps, [])

    def test_each_fix_gets_the_road_and_limit_the_map_has_for_it(self):
        fake = service(answer_for(4, limit_kmh=48, way=77, names=("Welsh Street", "B4293")))

        roads = fake.trace().match(line(4, 10))

        self.assertEqual(len(roads), 4)
        self.assertEqual(roads[0].limit_mph, 30)
        self.assertEqual(roads[0].way_id, 77)
        self.assertEqual(roads[0].names, ("Welsh Street", "B4293"))
        self.assertEqual(roads[0].road_class, "secondary")

    def test_a_fix_that_was_not_matched_has_no_road(self):
        fake = service(
            (
                200,
                {
                    "edges": [{"speed_limit": 32, "way_id": 1}],
                    "matched_points": [
                        {"type": "matched", "edge_index": 0},
                        {"type": "unmatched"},
                        {"type": "interpolated", "edge_index": 0},
                        {"type": "matched", "edge_index": 9},
                    ],
                },
            )
        )

        roads = fake.trace().match(line(4, 10))

        self.assertEqual([road is not None for road in roads], [True, False, True, False])

    def test_an_edge_with_no_limit_is_a_road_with_no_limit(self):
        fake = service(
            (
                200,
                {
                    "edges": [{"way_id": 5, "names": ["Lane"]}],
                    "matched_points": [{"type": "matched", "edge_index": 0}] * 2,
                },
            )
        )

        roads = fake.trace().match(line(2, 10))

        self.assertIsNone(roads[0].limit_mph)
        self.assertEqual(roads[0].way_id, 5)

    def test_a_busy_service_is_asked_once_more_after_a_pause(self):
        fake = service((429, {"error": "slow down"}), answer_for(3))

        roads = fake.trace().match(line(3, 10))

        self.assertEqual(len(fake.requests), 2)
        self.assertIn(5.0, fake.sleeps)
        self.assertEqual(roads[0].limit_mph, 20)
        self.assertEqual(len(fake.warnings), 1)

    def test_a_service_that_stays_busy_leaves_the_fixes_unchecked(self):
        fake = service((503, None))

        roads = fake.trace().match(line(3, 10))

        self.assertEqual(len(fake.requests), 2)
        self.assertEqual(roads, [None, None, None])
        self.assertTrue(fake.warnings)

    def test_a_refusal_names_the_reason_and_is_not_retried(self):
        fake = service((400, {"error": "Path distance exceeds the max distance limit"}))

        roads = fake.trace().match(line(3, 10))

        self.assertEqual(len(fake.requests), 1)
        self.assertEqual(roads, [None, None, None])
        self.assertIn("Path distance exceeds", fake.warnings[0])

    def test_an_unreachable_service_is_a_warning_not_a_crash(self):
        fake = service(audit.AuditError("Could not reach the speed-limit service: offline"))

        roads = fake.trace().match(line(3, 10))

        self.assertEqual(roads, [None, None, None])
        self.assertIn("offline", fake.warnings[0])

    def test_an_answer_that_is_not_a_trace_leaves_the_fixes_unchecked(self):
        for body in ({}, {"edges": "x", "matched_points": []}, []):
            fake = service((200, body))
            self.assertEqual(fake.trace().match(line(2, 10)), [None, None], msg=repr(body))

    def test_the_default_transport_will_only_speak_https(self):
        with self.assertRaises(audit.AuditError):
            audit.post_json("http://valhalla.example.test/trace_attributes", {}, {}, 1)


class StretchTest(unittest.TestCase):
    def stretch(self, count, spacing, mph, limit, **kwargs):
        return audit.find_stretches(fixes_of(line(count, spacing), mph, limit), **kwargs)

    def test_a_sustained_excess_over_a_long_enough_distance_is_reported(self):
        found = self.stretch(21, 15.1, 34, 20)  # 302 m

        self.assertEqual(len(found), 1)
        self.assertEqual(found[0].limit_mph, 20)
        self.assertAlmostEqual(found[0].median_mph, 34)
        self.assertAlmostEqual(found[0].distance_metres, 302, delta=1)
        self.assertEqual(found[0].way_ids, (1,))
        self.assertEqual(found[0].names, ("B4235",))
        self.assertEqual(found[0].fixes, 21)

    def test_the_threshold_is_inclusive_and_a_mph_under_it_is_not_reported(self):
        self.assertEqual(len(self.stretch(21, 15.1, 27.0, 20)), 1)
        self.assertEqual(self.stretch(21, 15.1, 26.9, 20), [])

    def test_the_threshold_is_the_operators_to_set(self):
        self.assertEqual(len(self.stretch(21, 15.1, 24, 20, threshold_mph=4)), 1)
        self.assertEqual(self.stretch(21, 15.1, 24, 20), [])

    def test_the_stretch_must_cover_the_minimum_distance(self):
        self.assertEqual(self.stretch(11, 13.0, 34, 20), [], "130 m")
        self.assertEqual(len(self.stretch(11, 15.1, 34, 20)), 1, "151 m")
        self.assertEqual(len(self.stretch(11, 13.0, 34, 20, min_distance_metres=100)), 1)

    def test_one_fix_is_never_a_stretch(self):
        self.assertEqual(self.stretch(1, 15.1, 90, 20), [])

    def test_a_dip_below_the_threshold_splits_the_stretch(self):
        points = line(40, 15.1)
        fixes = (
            fixes_of(points[:20], 34, 20)
            + fixes_of(points[20:21], 22, 20)
            + fixes_of(points[21:], 34, 20)
        )

        found = audit.find_stretches(fixes)

        self.assertEqual(len(found), 2)

    def test_a_change_of_limit_splits_the_stretch_so_each_way_stands_alone(self):
        points = line(40, 15.1)
        fixes = fixes_of(points[:20], 36, 20, way=1) + fixes_of(points[20:], 36, 30, way=2)

        found = audit.find_stretches(fixes, threshold_mph=5)

        self.assertEqual([stretch.limit_mph for stretch in found], [20, 30])
        self.assertEqual([stretch.way_ids for stretch in found], [(1,), (2,)])

    def test_two_ways_with_one_limit_are_one_stretch_naming_both(self):
        points = line(40, 15.1)
        fixes = fixes_of(points[:20], 34, 20, way=486644403) + fixes_of(
            points[20:], 34, 20, way=938784787
        )

        found = audit.find_stretches(fixes)

        self.assertEqual(len(found), 1)
        self.assertEqual(found[0].way_ids, (486644403, 938784787))

    def test_a_stretch_does_not_continue_across_a_break_in_the_recording(self):
        points = line(40, 15.1)
        fixes = fixes_of(points[:20], 34, 20, segment=0) + fixes_of(points[20:], 34, 20, segment=1)

        self.assertEqual(len(audit.find_stretches(fixes)), 2)

    def test_a_fix_with_no_speed_or_no_limit_ends_a_stretch(self):
        points = line(40, 15.1)
        fixes = fixes_of(points[:20], 34, 20) + fixes_of(points[20:], None, 20)
        self.assertEqual(len(audit.find_stretches(fixes)), 1)
        fixes = fixes_of(points[:20], 34, 20) + fixes_of(points[20:], 34, None)
        self.assertEqual(len(audit.find_stretches(fixes)), 1)

    def test_a_road_with_no_mapped_limit_is_never_a_finding(self):
        self.assertEqual(audit.find_stretches(fixes_of(line(40, 15.1), 90, None)), [])

    def test_the_median_is_the_speed_the_ride_held_not_its_peak(self):
        points = line(21, 15.1)
        speeds = [34] * 18 + [60, 60, 60]
        fixes = [
            audit.Fix(0, points[index], speeds[index], fixes_of(points, 0, 20)[0].road)
            for index in range(len(points))
        ]

        found = audit.find_stretches(fixes)

        self.assertEqual(found[0].median_mph, 34)
        self.assertEqual(found[0].maximum_mph, 60)

    def test_it_reports_where_and_when(self):
        points = line(21, 15.1, t0=1_000_000)

        found = audit.find_stretches(fixes_of(points, 34, 20))[0]

        self.assertEqual(found.start, points[0])
        self.assertEqual(found.end, points[-1])
        self.assertEqual(found.duration_seconds, 20)


class RecordedRideTest(NoNetworkTestCase):
    """The synthetic ride through the real code, with the answer Valhalla gave it."""

    def run_audit(self, recorded=None, **settings):
        fake = service((200, recorded if recorded is not None else RECORDED))
        segments = audit.read_gpx(str(RIDE))
        result = audit.audit(segments, fake.trace(), **settings)
        return result, fake

    def test_the_ride_beat_a_20_mph_limit_on_the_b4235(self):
        result, fake = self.run_audit()

        self.assertEqual(len(fake.requests), 1)
        self.assertEqual(len(fake.requests[0][1]["shape"]), 112)
        self.assertEqual(len(result.stretches), 1)
        stretch = result.stretches[0]
        self.assertEqual(stretch.way_ids, (486644403, 938784787))
        self.assertEqual(stretch.names, ("B4235",))
        self.assertEqual(stretch.road_classes, ("secondary",))
        self.assertEqual(stretch.limit_mph, 20)
        self.assertAlmostEqual(stretch.median_mph, 34, delta=1)
        self.assertAlmostEqual(stretch.distance_metres, 622, delta=10)

    def test_the_fixes_on_a_road_with_no_mapped_limit_are_counted_not_judged(self):
        result, _ = self.run_audit()

        self.assertEqual(result.fixes, 112)
        self.assertEqual(result.with_limit, 80)
        self.assertEqual(result.without_limit, 32)
        self.assertEqual(result.unmatched_or_unchecked, 0)
        self.assertEqual(result.requests, 1)

    def test_once_the_map_says_30_the_ride_is_no_longer_a_finding(self):
        corrected = copy.deepcopy(RECORDED)
        for edge in corrected["edges"]:
            if edge.get("speed_limit") == 32:
                edge["speed_limit"] = 48

        result, _ = self.run_audit(corrected)

        self.assertEqual(result.stretches, [], "34 mph through a 30 is +4, under the threshold")

    def test_a_looser_threshold_finds_it_there_too(self):
        corrected = copy.deepcopy(RECORDED)
        for edge in corrected["edges"]:
            if edge.get("speed_limit") == 32:
                edge["speed_limit"] = 48

        result, _ = self.run_audit(corrected, threshold_mph=3)

        self.assertEqual(len(result.stretches), 1)
        self.assertEqual(result.stretches[0].limit_mph, 30)

    def test_a_ride_the_service_would_not_match_is_all_unchecked(self):
        fake = service((400, {"error": "no path"}))
        result = audit.audit(audit.read_gpx(str(RIDE)), fake.trace())

        self.assertEqual(result.stretches, [])
        self.assertEqual(result.unmatched_or_unchecked, 112)
        self.assertEqual(result.with_limit + result.without_limit, 0)

    def test_a_long_ride_is_asked_in_300_point_chunks_at_most_a_second_apart(self):
        points = line(650, 13.4112)
        fake = service(answer_for(300), answer_for(300), answer_for(50))

        result = audit.audit([points], fake.trace())

        self.assertEqual([len(request[1]["shape"]) for request in fake.requests], [300, 300, 50])
        gaps = intervals(fake.starts)
        self.assertTrue(all(gap >= 1.1 - 1e-9 for gap in gaps))
        self.assertEqual(result.fixes, 650)
        self.assertEqual(result.requests, 3)
        self.assertEqual(audit.request_count([points, line(10, 10)]), 4)


class ReportTest(NoNetworkTestCase):
    def report(self):
        result = audit.audit(audit.read_gpx(str(RIDE)), service((200, RECORDED)).trace())
        return result, audit.format_report(result)

    def test_the_report_names_the_ways_the_road_the_limit_and_the_speed(self):
        _, text = self.report()

        self.assertIn("B4235 - mapped 20 mph, median 34 mph (+14)", text)
        self.assertIn("way/486644403, way/938784787", text)
        self.assertIn("https://www.openstreetmap.org/way/486644403", text)
        self.assertIn("80 on a road with a mapped limit", text)

    def test_the_report_says_where_a_stretch_is_and_nothing_else_of_the_track(self):
        result, text = self.report()

        places = re.findall(r"-?\d+\.\d{5},-?\d+\.\d{5}", text)
        self.assertEqual(len(places), 2, "the start and the end of the one stretch")
        self.assertIn(f"{result.stretches[0].start.latitude:.5f}", places[0])

    def test_a_ride_with_nothing_to_report_says_so(self):
        result = audit.audit(
            audit.read_gpx(str(RIDE)), service(answer_for(112, limit_kmh=113)).trace()
        )

        self.assertIn("None.", audit.format_report(result))

    def test_the_json_carries_the_same_stretch_and_no_track(self):
        result, _ = self.report()

        document = audit.result_json(
            result, threshold_mph=7.0, min_distance_metres=150.0, window_seconds=20.0
        )

        self.assertEqual(set(document), {"parameters", "summary", "stretches"})
        stretch = document["stretches"][0]
        self.assertEqual(stretch["wayIds"], [486644403, 938784787])
        self.assertEqual(stretch["mappedLimitMph"], 20)
        self.assertEqual(set(stretch["start"]), {"lat", "lon", "time"})
        self.assertEqual(document["summary"]["fixes"], 112)
        self.assertNotIn("points", json.dumps(document).lower())


class CommandLineTest(NoNetworkTestCase):
    def run_main(self, *argv, answers=None):
        fake = service(*(answers or [(200, RECORDED)]))
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = audit.main(list(argv), post=fake.post, sleep=fake.sleep, clock=fake.clock)
        return code, out.getvalue(), err.getvalue(), fake

    def test_it_prints_the_report_and_says_how_long_it_will_take(self):
        code, out, err, fake = self.run_main(str(RIDE))

        self.assertEqual(code, 0)
        self.assertIn("way/486644403", out)
        self.assertIn("112 timed fixes in 1 segment(s): 1 request(s)", err)
        self.assertEqual(len(fake.requests), 1)

    def test_a_dry_run_asks_nothing(self):
        code, out, err, fake = self.run_main(str(RIDE), "--dry-run")

        self.assertEqual(code, 0)
        self.assertEqual(out, "")
        self.assertEqual(fake.requests, [])
        self.assertIn("1 request(s)", err)

    def test_the_json_is_written_only_when_asked_for(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "report.json"

            code, _, _, _ = self.run_main(str(RIDE), "--json", str(path))

            self.assertEqual(code, 0)
            self.assertEqual(json.loads(path.read_text())["stretches"][0]["wayIds"][0], 486644403)

    def test_the_options_reach_the_analysis(self):
        code, out, _, _ = self.run_main(str(RIDE), "--threshold-mph", "20")

        self.assertEqual(code, 0)
        self.assertIn("None.", out)
        self.assertIn("20 mph or more", out)

    def test_it_will_not_go_faster_than_a_request_a_second(self):
        code, _, err, fake = self.run_main(str(RIDE), "--interval-s", "0.5")

        self.assertEqual(code, 2)
        self.assertEqual(fake.requests, [])
        self.assertIn("one second", err)

    def test_a_ride_the_service_matched_none_of_is_an_error_not_a_clean_bill(self):
        code, out, err, _ = self.run_main(
            str(RIDE), answers=[(400, {"error": "no path could be found"})]
        )

        self.assertEqual(code, 2)
        self.assertEqual(out, "")
        self.assertIn("matched none of the ride", err)

    def test_a_file_that_is_not_a_ride_is_an_error(self):
        code, _, err, _ = self.run_main("/nonexistent/ride.gpx")

        self.assertEqual(code, 2)
        self.assertIn("Could not read", err)


if __name__ == "__main__":
    unittest.main()

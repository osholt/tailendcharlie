// The real MyRoute-app export a tester imported (#180).
//
// > Yeah screenshots do loops in 3 area's compared to MRA
//
// The app's Review route screen read 47.4 mi for a route MyRoute-app states as
// 37.59 km (23.4 mi), and drew loops the planner does not show. The file explains
// both: it carries the journey twice, as a 709-point calculated `<trk>` and as
// the 8-point `<rte>` of waypoints it was calculated from. The lengths were
// summed, and both lines were drawn, so the sparse one cut across the dense one
// wherever they diverged.
//
// The fixture is the tester's own file, committed unchanged, because inferring
// this from a screenshot is what it took to find it.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/map/route_review_screen.dart';
import 'package:ride_relay/services/gpx_parser.dart';

void main() {
  const parser = GpxParser();

  ImportedRoute importFixture() => parser.parse(
    File('test/fixtures/myrouteapp_uley_cafe.gpx').readAsBytesSync(),
    routeId: 'uley',
    sourceFileName: 'ABR Uley cafe .gpx',
    importedAt: DateTime.utc(2026, 7, 27),
  );

  test('the calculated track is kept and the duplicate route dropped', () {
    final route = importFixture();

    expect(
      route.paths,
      hasLength(1),
      reason: 'the <trk> and the <rte> describe one journey, so one path',
    );
    expect(route.paths.single.points, hasLength(709));
    expect(route.paths.single.kind, RoutePathKind.track);
  });

  test('the distance matches what MyRoute-app states for the route', () {
    // MyRoute-app: 37.59 km. Measured over the file's own track geometry:
    // 37.67 km. The 80 m is the earth model, not a routing difference.
    expect(routeLengthMeters(importFixture()), closeTo(37670, 400));
  });

  test('the waypoints keep their via and shaping semantics', () {
    final route = importFixture();

    // 6 trp:ShapingPoint and 2 trp:ViaPoint in the file. Dropping the redundant
    // path must not drop what the rider planned with.
    expect(route.waypoints, hasLength(8));
    expect(
      route.waypoints.where((point) => point.symbol == 'Shaping point'),
      hasLength(6),
    );
    expect(
      route.waypoints.where((point) => point.symbol == 'Via point'),
      hasLength(2),
    );
  });

  test('the retained geometry starts and ends where the file does', () {
    final points = importFixture().paths.single.points;

    expect(points.first.latitude, closeTo(51.44416, 0.00001));
    expect(points.first.longitude, closeTo(-2.47474, 0.00001));
    expect(points.last.latitude, closeTo(51.68363, 0.001));
  });

  test('a track and a genuinely different route both survive', () {
    // The conservative half of the rule: two paths that are not the same journey
    // are both kept, so a recording alongside a plan is not silently discarded.
    final route = parser.parse(
      _bytes('''
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>Yesterday</name><trkseg>
            <trkpt lat="51.00" lon="-2.00"/>
            <trkpt lat="51.01" lon="-2.00"/>
            <trkpt lat="51.02" lon="-2.00"/>
          </trkseg></trk>
          <rte><name>Tomorrow</name>
            <rtept lat="52.00" lon="-3.00"/>
            <rtept lat="52.01" lon="-3.00"/>
          </rte>
        </gpx>
      '''),
      routeId: 'two',
      sourceFileName: 'two.gpx',
      importedAt: DateTime.utc(2026, 7, 27),
    );

    expect(route.paths, hasLength(2));
  });

  test('a sparser route beside a denser track is the one dropped', () {
    // The mechanism, in miniature: identical journey, two densities. Before the
    // fix both paths were kept and their lengths added.
    final route = parser.parse(
      _bytes('''
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><name>Calculated</name><trkseg>
            <trkpt lat="51.000" lon="-2.000"/>
            <trkpt lat="51.005" lon="-2.000"/>
            <trkpt lat="51.010" lon="-2.000"/>
            <trkpt lat="51.015" lon="-2.000"/>
          </trkseg></trk>
          <rte><name>Waypoints</name>
            <rtept lat="51.000" lon="-2.000"/>
            <rtept lat="51.015" lon="-2.000"/>
          </rte>
        </gpx>
      '''),
      routeId: 'dense',
      sourceFileName: 'dense.gpx',
      importedAt: DateTime.utc(2026, 7, 27),
    );

    expect(route.paths, hasLength(1));
    expect(route.paths.single.name, 'Calculated');
  });
}

Uint8List _bytes(String xml) => Uint8List.fromList(utf8.encode(xml));

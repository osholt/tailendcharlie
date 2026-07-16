import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/gpx_parser.dart';

void main() {
  const parser = GpxParser();

  test('parses GPX 1.1 tracks, route points, waypoints, and metadata', () {
    final route = parser.parse(
      _bytes('''
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata><name>Mixed route</name><desc>Saturday</desc></metadata>
          <wpt lat="53.3" lon="-1.6"><name>Fuel</name><sym>Fuel</sym></wpt>
          <trk><name>Main track</name>
            <trkseg>
              <trkpt lat="53.1" lon="-1.4"><ele>200</ele><time>2026-07-16T09:00:00Z</time></trkpt>
              <trkpt lat="53.2" lon="-1.5" />
            </trkseg>
          </trk>
          <rte><name>Diversion</name><rtept lat="53.4" lon="-1.7" /></rte>
        </gpx>
      '''),
      routeId: 'route-1',
      sourceFileName: 'mixed.gpx',
      importedAt: DateTime.utc(2026, 7, 16),
    );

    expect(route.name, 'Mixed route');
    expect(route.description, 'Saturday');
    expect(route.paths, hasLength(2));
    expect(route.pathPointCount, 3);
    expect(route.paths.first.points.first.elevationMeters, 200);
    expect(route.paths.first.points.first.recordedAt, isNotNull);
    expect(route.waypoints.single.name, 'Fuel');
  });

  test('rejects invalid coordinates and excessive point counts', () {
    expect(
      () => parser.parse(
        _bytes('<gpx><wpt lat="91" lon="0" /></gpx>'),
        routeId: 'bad',
        sourceFileName: 'bad.gpx',
        importedAt: DateTime.utc(2026),
      ),
      throwsA(isA<GpxFormatException>()),
    );

    const limitedParser = GpxParser(maximumPoints: 1);
    expect(
      () => limitedParser.parse(
        _bytes(
          '<gpx><rte><rtept lat="1" lon="1"/><rtept lat="2" lon="2"/></rte></gpx>',
        ),
        routeId: 'large',
        sourceFileName: 'large.gpx',
        importedAt: DateTime.utc(2026),
      ),
      throwsA(isA<GpxFormatException>()),
    );
  });

  test('bundled demo is valid GPX geometry', () {
    final bytes = File('assets/demo_route.gpx').readAsBytesSync();
    final route = parser.parse(
      bytes,
      routeId: 'demo',
      sourceFileName: 'demo_route.gpx',
      importedAt: DateTime.utc(2026),
    );

    expect(route.name, 'Peak District demo loop');
    expect(route.pathPointCount, greaterThan(5));
    expect(route.waypoints, hasLength(2));
  });
}

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
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

  test('recognises a planner-calculated track as a road route', () {
    final route = parser.parse(
      _bytes('''
        <gpx version="1.1"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:tec="https://tailendcharlie.app/gpx/1">
          <trk>
            <extensions><tec:road-route>true</tec:road-route></extensions>
            <trkseg>
              <trkpt lat="53.1" lon="-1.4" />
              <trkpt lat="53.2" lon="-1.5" />
            </trkseg>
          </trk>
        </gpx>
      '''),
      routeId: 'planned',
      sourceFileName: 'planned.gpx',
      importedAt: DateTime.utc(2026, 7, 23),
    );

    expect(route.paths.single.kind.name, 'route');
  });

  test('imports reviewed marker decisions from the web planner', () {
    final route = parser.parse(
      _bytes('''
        <gpx version="1.1"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:tec="https://tailendcharlie.app/gpx/1">
          <metadata><extensions><tec:marker-review>
            <tec:rejected id="old-maneuver" lat="51.1000000" lon="-2.1000000"
              label="Turn right marker" />
            <tec:added id="geometry-4" lat="51.1500000" lon="-2.1500000"
              label="Missed junction" />
          </tec:marker-review></extensions></metadata>
          <trk><trkseg>
            <trkpt lat="51.0" lon="-2.0" />
            <trkpt lat="51.2" lon="-2.2" />
          </trkseg></trk>
        </gpx>
      '''),
      routeId: 'reviewed',
      sourceFileName: 'reviewed.gpx',
      importedAt: DateTime.utc(2026, 7, 29),
    );

    expect(route.markerReview.rejected.single.id, 'old-maneuver');
    expect(route.markerReview.rejected.single.label, 'Turn right marker');
    expect(route.markerReview.added.single.id, 'geometry-4');
    expect(route.markerReview.added.single.position.latitude, 51.15);
  });

  test('preserves Scenic soft points without importing duplicate routes', () {
    final route = parser.parse(
      _bytes('''
        <gpx version="1.1"
             creator="Scenic Motorcycle Navigation App"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:trp="http://www.garmin.com/xmlschemas/TripExtensions/v1"
             xmlns:gpxx="http://www.garmin.com/xmlschemas/GpxExtensions/v3">
          <wpt lat="51.0" lon="-2.0"><name>Start</name></wpt>
          <rte><name>Plain</name>
            <rtept lat="51.0" lon="-2.0"/>
            <rtept lat="51.1" lon="-2.1"/>
            <rtept lat="51.2" lon="-2.2"/>
          </rte>
          <rte><name>Garmin Trip</name>
            <rtept lat="51.0" lon="-2.0">
              <extensions><trp:ViaPoint/></extensions>
            </rtept>
            <rtept lat="51.1" lon="-2.1">
              <name>Via 1</name>
              <extensions><trp:ShapingPoint/></extensions>
            </rtept>
            <rtept lat="51.2" lon="-2.2">
              <extensions><trp:ViaPoint/></extensions>
            </rtept>
          </rte>
          <rte><name>Garmin RoutePoint</name>
            <rtept lat="51.0" lon="-2.0">
              <extensions><gpxx:RoutePointExtension>
                <gpxx:rpt lat="51.1" lon="-2.1"/>
              </gpxx:RoutePointExtension></extensions>
            </rtept>
            <rtept lat="51.2" lon="-2.2"/>
          </rte>
          <trk><name>Calculated track</name><trkseg>
            <trkpt lat="51.0" lon="-2.0"/>
            <trkpt lat="51.2" lon="-2.2"/>
          </trkseg></trk>
        </gpx>
      '''),
      routeId: 'scenic',
      sourceFileName: 'scenic.gpx',
      importedAt: DateTime.utc(2026, 7, 24),
    );

    expect(route.paths, hasLength(2));
    expect(
      route.paths.where((path) => path.kind.name == 'route').single.name,
      'Garmin Trip',
    );
    expect(
      route.waypoints.where((waypoint) => waypoint.symbol == 'Shaping point'),
      hasLength(1),
    );
    expect(
      route.waypoints
          .where((waypoint) => waypoint.symbol == 'Shaping point')
          .single
          .name,
      'Via 1',
    );
  });

  test('Garmin RoutePoint extension points shape the line without becoming '
      'waypoints', () {
    final route = parser.parse(
      _bytes('''
        <gpx version="1.1"
             xmlns="http://www.topografix.com/GPX/1/1"
             xmlns:gpxx="http://www.garmin.com/xmlschemas/GpxExtensions/v3">
          <rte><name>Garmin route</name>
            <rtept lat="51.0" lon="-2.0">
              <extensions><gpxx:RoutePointExtension>
                <gpxx:rpt lat="51.1" lon="-2.1"/>
                <gpxx:rpt lat="51.2" lon="-2.2"/>
              </gpxx:RoutePointExtension></extensions>
            </rtept>
            <rtept lat="51.3" lon="-2.3"/>
          </rte>
        </gpx>
      '''),
      routeId: 'garmin',
      sourceFileName: 'garmin.gpx',
      importedAt: DateTime.utc(2026, 7, 24),
    );

    // Unchanged, and the half that was always right: the extension points are
    // the decoded shape of the leg and belong in the line, in order.
    expect(route.paths.single.points.map((point) => point.latitude), [
      51.0,
      51.1,
      51.2,
      51.3,
    ]);
    // Changed deliberately (#574). This used to expect two "Shaping point"
    // waypoints, which is what the parser did and what the defect was.
    // `<gpxx:rpt>` is Garmin's calculated road geometry, not a place anybody
    // chose, and rendering every vertex as a marker put 6960 yellow badges
    // over a 296 km import. A rider's real via and shaping points carry
    // `<trp:ViaPoint>`/`<trp:ShapingPoint>` and are still read — see the two
    // tests above and the MyRoute-app fixture suite, which assert exactly that
    // and are untouched by this change.
    expect(route.waypoints, isEmpty);
  });

  group('a dense Garmin export stays one readable line (#574)', () {
    // The shape of the MyRouteApp day run that was reported: one <rte> whose
    // rtept legs carry their decoded geometry inline, and one <trk> of the
    // same journey at very nearly the same density. Small enough to read here;
    // the relationships between the two are what matter.
    String denseGarminGpx({required int rptPerLeg, required int trackPoints}) {
      final rpt = List.generate(
        rptPerLeg,
        (i) => '<gpxx:rpt lat="${51.0 + i * 0.0001}" lon="-2.0"/>',
      ).join();
      final track = List.generate(
        trackPoints,
        (i) => '<trkpt lat="${51.0 + i * 0.0001}" lon="-2.0"/>',
      ).join();
      return '<gpx version="1.1" creator="MyRouteApp" '
          'xmlns="http://www.topografix.com/GPX/1/1" '
          'xmlns:gpxx="http://www.garmin.com/xmlschemas/GpxExtensions/v3" '
          'xmlns:trp="http://www.garmin.com/xmlschemas/TripExtensions/v1">'
          '<rte><name>Day run</name>'
          '<rtept lat="51.0" lon="-2.0"><extensions><trp:ViaPoint/>'
          '<gpxx:RoutePointExtension>$rpt</gpxx:RoutePointExtension>'
          '</extensions></rtept>'
          '<rtept lat="51.04" lon="-2.0"><extensions><trp:ViaPoint/>'
          '</extensions></rtept>'
          '</rte>'
          '<trk><name>Day run track</name><trkseg>$track</trkseg></trk>'
          '</gpx>';
    }

    ImportedRoute parse(String gpx) => parser.parse(
      _bytes(gpx),
      routeId: 'dense',
      sourceFileName: 'dense.gpx',
      importedAt: DateTime.utc(2026, 8, 16),
    );

    test('leg geometry does not become a carpet of waypoints', () {
      final route = parse(denseGarminGpx(rptPerLeg: 400, trackPoints: 400));

      // Two, because the file names two via points. Before this fix it was
      // 402: every decoded vertex arrived as a rendered, listed marker.
      expect(route.waypoints, hasLength(2));
      expect(
        route.waypoints.every((point) => point.symbol == 'Via point'),
        isTrue,
      );
    });

    test('two encodings of one journey draw one line', () {
      final route = parse(denseGarminGpx(rptPerLeg: 400, trackPoints: 400));

      expect(
        route.paths,
        hasLength(1),
        reason: 'the <rte> and the <trk> are the same ride',
      );
      expect(route.paths.single.kind, RoutePathKind.track);
    });

    test('a route marginally denser than the track is still the duplicate', () {
      // The exact miss in #180's guard, which required the track be strictly
      // denser: decoding the legs inline puts the route representation
      // slightly ahead, so both were kept and the ride was measured twice.
      final route = parse(denseGarminGpx(rptPerLeg: 420, trackPoints: 400));

      expect(route.paths, hasLength(1));
      expect(route.paths.single.kind, RoutePathKind.track);
    });

    test('a genuinely sparser track does not swallow a detailed route', () {
      // The protection #180 was reaching for, kept: an order-of-magnitude gap
      // is two different representations, not two encodings of one.
      final route = parse(denseGarminGpx(rptPerLeg: 400, trackPoints: 3));

      expect(route.paths, hasLength(2));
    });
  });

  test('bundled demo is valid GPX geometry', () {
    final bytes = File('assets/demo_route.gpx').readAsBytesSync();
    final route = parser.parse(
      bytes,
      routeId: 'demo',
      sourceFileName: 'demo_route.gpx',
      importedAt: DateTime.utc(2026),
    );

    expect(route.name, "King's Oak Academy to Cross Hands Hotel");
    expect(route.pathPointCount, greaterThan(450));
    expect(route.waypoints, hasLength(3));
    expect(route.paths.single.kind.name, 'track');
    expect(
      route.paths.single.points.first.latitude,
      closeTo(51.462674, 0.00001),
    );
    expect(
      route.paths.single.points.last.latitude,
      closeTo(51.528729, 0.00001),
    );
  });
}

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

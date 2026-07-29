import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/gpx_exporter.dart';
import 'package:ride_relay/services/gpx_parser.dart';

void main() {
  test('exports valid GPX 1.1 tracks, routes, and waypoints', () {
    final route = ImportedRoute(
      id: 'route-1',
      name: 'Peaks & Dales',
      description: 'Saturday <test>',
      importedAt: DateTime.utc(2026, 7, 16, 8),
      sourceFileName: 'source.gpx',
      paths: [
        RoutePath(
          kind: RoutePathKind.track,
          name: 'Track A',
          points: [
            GeoPoint(
              latitude: 53.1,
              longitude: -1.2,
              elevationMeters: 240,
              recordedAt: DateTime.utc(2026, 7, 16, 8, 1),
            ),
            const GeoPoint(latitude: 53.2, longitude: -1.3),
          ],
        ),
        const RoutePath(
          kind: RoutePathKind.route,
          name: 'Diversion',
          points: [GeoPoint(latitude: 53.3, longitude: -1.4)],
        ),
      ],
      waypoints: const [
        RouteWaypoint(
          point: GeoPoint(latitude: 53.4, longitude: -1.5),
          name: 'Fuel & food',
        ),
      ],
      markerReview: const MarkerPlanReview(
        rejected: [
          MarkerReviewPoint(
            id: 'maneuver-2',
            position: GeoPoint(latitude: 53.15, longitude: -1.25),
            label: 'Turn left marker',
          ),
        ],
        added: [
          MarkerReviewPoint(
            id: 'geometry-4',
            position: GeoPoint(latitude: 53.16, longitude: -1.26),
            label: 'Missed junction',
          ),
        ],
      ),
    );
    const exporter = GpxExporter();

    final exported = exporter.export(route);
    final parsed = const GpxParser().parse(
      Uint8List.fromList(utf8.encode(exported)),
      routeId: 'round-trip',
      sourceFileName: exporter.fileName(route),
      importedAt: DateTime.utc(2026, 7, 17),
    );

    expect(exported, contains('xmlns="http://www.topografix.com/GPX/1/1"'));
    expect(parsed.paths, hasLength(2));
    expect(parsed.pathPointCount, 3);
    expect(parsed.waypoints.single.name, 'Fuel & food');
    expect(parsed.markerReview.rejected.single.id, 'maneuver-2');
    expect(parsed.markerReview.added.single.label, 'Missed junction');
    expect(exporter.fileName(route), 'peaks-dales.gpx');
  });
}

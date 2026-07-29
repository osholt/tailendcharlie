import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/map/resolved_route_map_preview.dart';

void main() {
  test('route preview bounds include every route segment', () {
    final bounds = routePreviewBounds(const [
      GeoPoint(latitude: 54.1, longitude: -2.3),
      GeoPoint(latitude: 53.2, longitude: -0.8),
      GeoPoint(latitude: 52.8, longitude: -1.4),
    ]);

    expect(bounds.southwest.latitude, 52.8);
    expect(bounds.southwest.longitude, closeTo(-2.3, 1e-9));
    expect(bounds.northeast.latitude, 54.1);
    expect(bounds.northeast.longitude, closeTo(-0.8, 1e-9));
  });

  test(
    'framing includes start and destination pins outside sparse geometry',
    () {
      final points = routePreviewFramingPoints(
        const [
          [
            GeoPoint(latitude: 51.46, longitude: -2.3),
            GeoPoint(latitude: 51.47, longitude: -2.2),
          ],
        ],
        const [
          RoutePreviewPin(
            point: GeoPoint(latitude: 51.45, longitude: -2.5),
            kind: 'start',
          ),
          RoutePreviewPin(
            point: GeoPoint(latitude: 51.5, longitude: -2.0),
            kind: 'finish',
          ),
        ],
      );
      final bounds = routePreviewBounds(points);

      expect(bounds.southwest.longitude, -2.5);
      expect(bounds.northeast.longitude, -2.0);
    },
  );
}

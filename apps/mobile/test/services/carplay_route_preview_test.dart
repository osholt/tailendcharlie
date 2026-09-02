import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/carplay_route_preview.dart';
import 'package:ride_relay/services/road_routing.dart';

void main() {
  test(
    'a preview is immutable, bounded to three choices, and serializable',
    () {
      final preview = CarPlayTripPreview(
        id: 'preview-1',
        destinationLabel: 'Puy Mary, France',
        choices: [
          for (var index = 0; index < 4; index += 1)
            CarPlayRouteChoicePreview.fromPlan(
              _plan('route-$index', distance: 10000 + index * 1000),
              suffix: 'choice-$index',
              summary: 'Route ${index + 1}',
            ),
        ],
      );

      expect(preview.choices, hasLength(3));
      expect(preview.origin.latitude, 45.05);
      expect(preview.destination.longitude, 2.72);
      expect(preview.toSnapshot(), {
        'schemaVersion': 1,
        'id': 'preview-1',
        'destinationLabel': 'Puy Mary, France',
        'origin': {'latitude': 45.05, 'longitude': 2.7},
        'destination': {'latitude': 45.06, 'longitude': 2.72},
        'choices': hasLength(3),
      });
    },
  );

  test('committing consumes a preview exactly once', () {
    final transaction = CarPlayRoutePreviewTransaction();
    transaction.replace(
      CarPlayTripPreview.single(
        destinationLabel: 'Puy Mary, France',
        plan: _plan('route-1'),
      ),
    );

    final selected = transaction.commit(
      previewId: 'route-1:carplay-preview',
      routeChoiceId: 'route-1:primary',
    );

    expect(selected.route.id, 'route-1');
    expect(selected.destinationLabel, 'Puy Mary, France');
    expect(
      () => transaction.commit(
        previewId: 'route-1:carplay-preview',
        routeChoiceId: 'route-1:primary',
      ),
      throwsFormatException,
    );
  });

  test('cancelling a preview leaves no route to commit', () {
    final transaction = CarPlayRoutePreviewTransaction();
    transaction.replace(
      CarPlayTripPreview.single(
        destinationLabel: 'Puy Mary, France',
        plan: _plan('route-1'),
      ),
    );

    transaction.cancel('route-1:carplay-preview');

    expect(transaction.pending, isNull);
    expect(
      () => transaction.commit(
        previewId: 'route-1:carplay-preview',
        routeChoiceId: 'route-1:primary',
      ),
      throwsFormatException,
    );
  });

  test('a malformed route cannot become a CarPlay preview', () {
    final plan = DestinationRoutePlan(
      route: ImportedRoute(
        id: 'empty',
        name: 'Empty',
        importedAt: DateTime.utc(2026, 9, 2),
        sourceFileName: 'empty.gpx',
        paths: const [],
        waypoints: const [],
      ),
      distanceMeters: 0,
      duration: Duration.zero,
    );

    expect(
      () => CarPlayTripPreview.single(destinationLabel: 'Nowhere', plan: plan),
      throwsFormatException,
    );
  });
}

DestinationRoutePlan _plan(String id, {double distance = 12000}) =>
    DestinationRoutePlan(
      route: ImportedRoute(
        id: id,
        name: 'To Puy Mary',
        importedAt: DateTime.utc(2026, 9, 2),
        sourceFileName: '$id.gpx',
        paths: const [
          RoutePath(
            kind: RoutePathKind.track,
            points: [
              GeoPoint(latitude: 45.05, longitude: 2.7),
              GeoPoint(latitude: 45.06, longitude: 2.72),
            ],
          ),
        ],
        waypoints: const [],
      ),
      distanceMeters: distance,
      duration: const Duration(minutes: 20),
    );

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
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

  test('Android reshape gestures use native-view pixels', () {
    expect(
      previewPlatformPixelScale(
        platform: TargetPlatform.android,
        devicePixelRatio: 3,
      ),
      3,
    );
    expect(
      previewPlatformPixelScale(
        platform: TargetPlatform.iOS,
        devicePixelRatio: 3,
      ),
      1,
    );
  });

  test('POI pins do not expand the fitted route viewport', () {
    final points = routePreviewFramingPoints(
      const [
        [
          GeoPoint(latitude: 51.46, longitude: -2.5),
          GeoPoint(latitude: 51.5, longitude: -2.2),
        ],
      ],
      const [
        RoutePreviewPin(
          point: GeoPoint(latitude: 57, longitude: -4),
          kind: 'poi',
          includeInFraming: false,
        ),
      ],
    );

    final bounds = routePreviewBounds(points);
    expect(bounds.northeast.latitude, 51.5);
    expect(bounds.southwest.longitude, -2.5);
  });

  test('reshape zoom steps preserve the map limits', () {
    expect(
      routePreviewZoomTarget(currentZoom: 12, delta: 1, maximumZoom: 18),
      13,
    );
    expect(
      routePreviewZoomTarget(currentZoom: 18, delta: 1, maximumZoom: 18),
      18,
    );
    expect(
      routePreviewZoomTarget(currentZoom: 3, delta: -1, maximumZoom: 18),
      3,
    );
  });

  testWidgets('reshape zoom controls expose independent in and out actions', (
    tester,
  ) async {
    var zoomInCount = 0;
    var zoomOutCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RoutePreviewZoomControls(
              onZoomIn: () => zoomInCount += 1,
              onZoomOut: () => zoomOutCount += 1,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('route-preview-zoom-in')));
    await tester.tap(find.byKey(const Key('route-preview-zoom-out')));

    expect(zoomInCount, 1);
    expect(zoomOutCount, 1);
  });
}

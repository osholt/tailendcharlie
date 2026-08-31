import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/map/flutter_vector_route_preview.dart';

void main() {
  test('library thumbnail padding leaves room to fit the complete track', () {
    const viewport = Size.square(52);

    final padding = routePreviewCameraPadding(viewport);

    expect(padding, const EdgeInsets.all(14));
    expect(viewport.width - padding.horizontal, 24);
    expect(viewport.height - padding.vertical, 24);
  });

  test('normal route previews retain the full camera inset', () {
    expect(
      routePreviewCameraPadding(const Size(390, 220)),
      const EdgeInsets.all(30),
    );
  });

  test(
    'ride-library endpoint markers stay small enough to reveal the route',
    () {
      const viewport = Size.square(52);

      final diameter = routePreviewEndpointMarkerDiameter(viewport);

      expect(diameter, lessThanOrEqualTo(8));
      expect(diameter, lessThan(viewport.shortestSide / 6));
    },
  );

  test('full route previews retain clearly visible endpoint markers', () {
    expect(routePreviewEndpointMarkerDiameter(const Size(390, 220)), 18);
  });
}

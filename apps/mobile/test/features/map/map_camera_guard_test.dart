import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/map/map_camera_guard.dart';
import 'package:ride_relay/features/map/resolved_route_map_preview.dart';
import 'package:ride_relay/features/ride/previous_rides_screen.dart';

void main() {
  group('MapLibreCameraGuard', () {
    test('accepts an ordinary box', () {
      final bounds = ml.LatLngBounds(
        southwest: const ml.LatLng(51.4, -2.6),
        northeast: const ml.LatLng(51.5, -2.5),
      );

      expect(bounds.isUsableCamera, isTrue);
    });

    test('refuses a box with no width or height', () {
      // Not a frame. `constrainCameraAndZoomToBounds` unprojects from it and
      // `mbgl::LatLng` throws, which aborts the process rather than raising
      // anything Dart can catch (#359).
      //
      // Equal corners are the shape that actually gets this far: `LatLngBounds`
      // asserts on corners the wrong way round, so those are caught in debug,
      // but a box with no width at all is constructed happily.
      final collapsed = ml.LatLngBounds(
        southwest: const ml.LatLng(51.4, -2.6),
        northeast: const ml.LatLng(51.4, -2.6),
      );

      expect(collapsed.isUsableCamera, isFalse);
    });

    test('refuses a point the renderer cannot accept', () {
      // NaN is the case that matters. `ml.LatLng` clamps an out-of-range
      // latitude to +/-90 at the Dart boundary - `ml.LatLng(91, ...)` reports
      // 90 - so an overshoot never reaches the renderer, but NaN passes
      // straight through it and reaches `mbgl::LatLng`, which throws.
      expect(ml.LatLng(91, -2.5).latitude, 90);
      expect(
        mapLibreCameraIsUsable(const ml.LatLng(double.nan, -2.5)),
        isFalse,
      );
      expect(
        mapLibreCameraIsUsable(const ml.LatLng(51.4, double.nan)),
        isFalse,
      );
      expect(
        mapLibreCameraIsUsable(
          const ml.LatLng(51.4, -2.5),
          zoom: double.infinity,
        ),
        isFalse,
      );
      expect(
        mapLibreCameraIsUsable(const ml.LatLng(51.4, -2.5), zoom: 14),
        isTrue,
      );
    });
  });

  group('the collapsed box is reachable, not hypothetical', () {
    // A phone that never got a second fix stores a ride whose every point is
    // the same coordinate. Both screens frame stored points, so a ride like
    // that crashed every time it was opened - the value outlives the ride that
    // produced it.
    const stuck = [
      GeoPoint(latitude: 51.4672, longitude: -2.4889),
      GeoPoint(latitude: 51.4672, longitude: -2.4889),
      GeoPoint(latitude: 51.4672, longitude: -2.4889),
    ];

    test('an archived ride with one repeated fix collapses', () {
      expect(archivedRideBounds(stuck).isUsableCamera, isFalse);
    });

    test('a route preview with one repeated fix collapses', () {
      expect(routePreviewBounds(stuck).isUsableCamera, isFalse);
    });

    test('a real ride still frames', () {
      const ridden = [
        GeoPoint(latitude: 51.4672, longitude: -2.4889),
        GeoPoint(latitude: 51.4700, longitude: -2.4800),
      ];

      expect(archivedRideBounds(ridden).isUsableCamera, isTrue);
      expect(routePreviewBounds(ridden).isUsableCamera, isTrue);
    });
  });
}

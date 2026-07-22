import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/navigation_camera.dart';

void main() {
  test('widens and tilts gradually from rest to higher road speed', () {
    final rest = NavigationCameraPlanner.plan(
      speedMetersPerSecond: 0,
      landscape: false,
    );
    final urban = NavigationCameraPlanner.plan(
      speedMetersPerSecond: 12,
      landscape: false,
    );
    final higherRoad = NavigationCameraPlanner.plan(
      speedMetersPerSecond: 28,
      landscape: false,
    );

    expect(rest.zoom, greaterThan(urban.zoom));
    expect(urban.zoom, greaterThan(higherRoad.zoom));
    expect(rest.tilt, lessThan(urban.tilt));
    expect(urban.tilt, lessThan(higherRoad.tilt));
  });

  test('landscape preserves a wider road-ahead view', () {
    final portrait = NavigationCameraPlanner.plan(
      speedMetersPerSecond: 15,
      landscape: false,
    );
    final landscape = NavigationCameraPlanner.plan(
      speedMetersPerSecond: 15,
      landscape: true,
    );

    expect(landscape.zoom, lessThan(portrait.zoom));
    expect(landscape.tilt, greaterThan(portrait.tilt));
  });

  test('missing, invalid, and extreme speeds remain bounded', () {
    final missing = NavigationCameraPlanner.plan(
      speedMetersPerSecond: null,
      landscape: false,
    );
    final invalid = NavigationCameraPlanner.plan(
      speedMetersPerSecond: double.nan,
      landscape: false,
    );
    final extreme = NavigationCameraPlanner.plan(
      speedMetersPerSecond: 100,
      landscape: false,
    );

    expect(invalid.zoom, missing.zoom);
    expect(extreme.zoom, greaterThanOrEqualTo(13.8));
    expect(extreme.tilt, lessThanOrEqualTo(56));
  });
}

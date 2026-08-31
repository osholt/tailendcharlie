import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/navigation_camera.dart';

const _portraitHeight = 844.0;
const _landscapeHeight = 390.0;
const _fieldOfView = 0.6435011087932844;

/// Ground pixels between the camera target and a screen row [pixelsFromCentre]
/// above it, for the same camera model the planner assumes. Used to check the
/// planner's own geometry from the outside.
double _groundPixelsFromCentre(
  double pixelsFromCentre,
  double tiltDegrees,
  double viewportHeight,
) {
  final cameraToCentre = 0.5 * viewportHeight / math.tan(_fieldOfView / 2);
  final tilt = tiltDegrees * math.pi / 180;
  return cameraToCentre *
      math.cos(tilt) *
      (math.tan(tilt + math.atan(pixelsFromCentre / cameraToCentre)) -
          math.tan(tilt));
}

double _metersPerPixel(double zoom, double latitude) =>
    78271.5169 * math.cos(latitude * math.pi / 180) / math.pow(2, zoom);

/// Visible ground distance ahead of and behind the rider for a plan.
({double ahead, double behind}) _visibleDepth(
  NavigationCameraPlan plan,
  double viewportHeight,
  double latitude,
) {
  final scale = _metersPerPixel(plan.zoom, latitude);
  final rider = _groundPixelsFromCentre(
    -plan.forwardBiasPixels,
    plan.tilt,
    viewportHeight,
  );
  final top = _groundPixelsFromCentre(
    0.5 * viewportHeight,
    plan.tilt,
    viewportHeight,
  );
  final bottom = _groundPixelsFromCentre(
    -0.5 * viewportHeight,
    plan.tilt,
    viewportHeight,
  );
  return (ahead: (top - rider) * scale, behind: (rider - bottom) * scale);
}

NavigationCameraPlan _plan(
  double speed, {
  required bool landscape,
  double bottomChromeFraction = 0,
}) => NavigationCameraPlanner.plan(
  speedMetersPerSecond: speed,
  landscape: landscape,
  viewportHeightPixels: landscape ? _landscapeHeight : _portraitHeight,
  latitudeDegrees: 53,
  bottomChromeFraction: bottomChromeFraction,
);

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
    expect(invalid.riderViewportFraction, missing.riderViewportFraction);
    expect(extreme.zoom, greaterThanOrEqualTo(13.8));
    expect(extreme.tilt, lessThanOrEqualTo(navigationCameraMaximumTiltDegrees));
    expect(
      extreme.lookAheadMeters,
      lessThanOrEqualTo(navigationCameraMaximumLookAheadMeters),
    );
  });

  test('tilt stays inside the range MapLibre can actually render', () {
    for (final landscape in [false, true]) {
      for (var speed = 0.0; speed <= 40; speed += 0.5) {
        final plan = _plan(speed, landscape: landscape);
        // MapLibre Native clamps pitch at 60 degrees on both platforms.
        expect(plan.tilt, lessThanOrEqualTo(58));
        expect(plan.tilt, greaterThanOrEqualTo(51));
      }
    }
  });

  test('the rider is biased low in the frame, more so with speed', () {
    final restPortrait = _plan(0, landscape: false);
    final urbanPortrait = _plan(13, landscape: false);
    final roadPortrait = _plan(29, landscape: false);

    expect(restPortrait.riderViewportFraction, closeTo(0.62, 0.001));
    expect(urbanPortrait.riderViewportFraction, closeTo(0.652, 0.005));
    expect(roadPortrait.riderViewportFraction, closeTo(0.70, 0.005));
    expect(roadPortrait.forwardBiasPixels, closeTo(168, 2));

    final restLandscape = _plan(0, landscape: true);
    final roadLandscape = _plan(29, landscape: true);
    expect(restLandscape.riderViewportFraction, closeTo(0.64, 0.001));
    expect(roadLandscape.riderViewportFraction, closeTo(0.72, 0.005));
    // The landscape viewport is shorter, so the same fraction is fewer pixels.
    expect(
      roadLandscape.forwardBiasPixels,
      lessThan(roadPortrait.forwardBiasPixels),
    );

    for (final landscape in [false, true]) {
      var previous = 0.0;
      for (var speed = 0.0; speed <= 30; speed += 0.5) {
        final fraction = _plan(
          speed,
          landscape: landscape,
        ).riderViewportFraction;
        expect(fraction, greaterThanOrEqualTo(previous));
        expect(fraction, greaterThanOrEqualTo(0.5));
        expect(fraction, lessThanOrEqualTo(0.75));
        previous = fraction;
      }
    }
  });

  test('landscape stays in the open right third for either driving side', () {
    final leftTraffic = NavigationCameraPlanner.plan(
      speedMetersPerSecond: 13,
      landscape: true,
      viewportHeightPixels: 390,
      viewportWidthPixels: 840,
      leftHandTraffic: true,
    );
    final rightTraffic = NavigationCameraPlanner.plan(
      speedMetersPerSecond: 13,
      landscape: true,
      viewportHeightPixels: 390,
      viewportWidthPixels: 840,
      leftHandTraffic: false,
    );
    final portrait = NavigationCameraPlanner.plan(
      speedMetersPerSecond: 13,
      landscape: false,
      viewportHeightPixels: 840,
      viewportWidthPixels: 390,
      leftHandTraffic: false,
    );

    expect(leftTraffic.riderHorizontalViewportFraction, closeTo(2 / 3, 1e-9));
    expect(rightTraffic.riderHorizontalViewportFraction, closeTo(2 / 3, 1e-9));
    expect(leftTraffic.lateralBiasPixels, closeTo(140, 0.01));
    expect(rightTraffic.lateralBiasPixels, closeTo(140, 0.01));
    expect(portrait.riderHorizontalViewportFraction, 0.5);
    expect(portrait.lateralBiasPixels, 0);
  });

  test('France landscape framing clears the fixed left rail', () {
    final plan = NavigationCameraPlanner.plan(
      speedMetersPerSecond: 13,
      landscape: true,
      viewportHeightPixels: 1179,
      viewportWidthPixels: 2556,
      leftHandTraffic: false,
    );

    expect(plan.riderHorizontalViewportFraction * 2556, closeTo(1704, 0.01));
    expect(plan.lateralBiasPixels, closeTo(426, 0.01));
  });

  test('look-ahead scales with speed and stays bounded', () {
    for (final landscape in [false, true]) {
      final rest = _plan(0, landscape: landscape);
      final urban = _plan(13, landscape: landscape);
      final road = _plan(29, landscape: landscape);

      expect(rest.lookAheadMeters, greaterThan(0));
      expect(urban.lookAheadMeters, greaterThan(rest.lookAheadMeters));
      expect(road.lookAheadMeters, greaterThan(urban.lookAheadMeters));
      expect(
        road.lookAheadMeters,
        lessThanOrEqualTo(navigationCameraMaximumLookAheadMeters),
      );
    }
    expect(_plan(29, landscape: false).lookAheadMeters, closeTo(834, 15));
    expect(_plan(29, landscape: true).lookAheadMeters, closeTo(589, 15));
  });

  test('the look-ahead lands the rider exactly on the planned fraction', () {
    for (final landscape in [false, true]) {
      final height = landscape ? _landscapeHeight : _portraitHeight;
      for (final speed in [0.0, 8.0, 17.0, 29.0]) {
        final plan = _plan(speed, landscape: landscape);
        // Reconstruct the rider's screen row from the look-ahead distance the
        // planner produced. It has to be the fraction that was asked for,
        // otherwise the forward bias is a guess rather than geometry.
        final scale = _metersPerPixel(plan.zoom, 53);
        final lookAheadPixels = plan.lookAheadMeters / scale;
        final cameraToCentre = 0.5 * height / math.tan(_fieldOfView / 2);
        final tilt = plan.tilt * math.pi / 180;
        final riderRayTangent =
            math.tan(tilt) -
            lookAheadPixels / (cameraToCentre * math.cos(tilt));
        final riderAngle = math.atan(riderRayTangent) - tilt;
        final riderPixelsBelowCentre = -cameraToCentre * math.tan(riderAngle);
        expect(
          0.5 + riderPixelsBelowCentre / height,
          closeTo(plan.riderViewportFraction, 0.002),
        );
      }
    }
  });

  test('most of the frame is road ahead at rest, urban and road speed', () {
    for (final landscape in [false, true]) {
      final height = landscape ? _landscapeHeight : _portraitHeight;
      for (final speed in [0.0, 13.0, 29.0]) {
        final depth = _visibleDepth(
          _plan(speed, landscape: landscape),
          height,
          53,
        );
        expect(
          depth.ahead,
          greaterThan(depth.behind * 3),
          reason: 'speed $speed landscape $landscape',
        );
      }
    }
  });

  test(
    'the bottom chrome band pulls the bias back, never under an overlay',
    () {
      // Portrait chrome sits directly under the rider, so a tall band has to
      // reduce the bias rather than hide the marker.
      final light = _plan(29, landscape: false, bottomChromeFraction: 0.2);
      final medium = _plan(29, landscape: false, bottomChromeFraction: 0.3);
      final heavy = _plan(29, landscape: false, bottomChromeFraction: 0.42);
      final absurd = _plan(29, landscape: false, bottomChromeFraction: 0.9);

      expect(light.riderViewportFraction, closeTo(0.70, 0.005));
      expect(medium.riderViewportFraction, closeTo(0.64, 0.005));
      expect(heavy.riderViewportFraction, closeTo(0.52, 0.005));
      // A band tall enough to cover the centre of the frame gives up the
      // forward bias entirely rather than hiding the rider's own marker.
      expect(
        absurd.riderViewportFraction,
        navigationCameraMinimumRiderFraction,
      );
      expect(absurd.forwardBiasPixels, lessThan(0));
      expect(absurd.lookAheadMeters, lessThan(0));

      for (var chrome = 0.0; chrome <= 0.9; chrome += 0.01) {
        final plan = _plan(29, landscape: false, bottomChromeFraction: chrome);
        final visibleLimit = math.max(
          navigationCameraMinimumRiderFraction,
          1 - chrome - navigationCameraRiderChromeClearanceFraction,
        );
        expect(
          plan.riderViewportFraction,
          lessThanOrEqualTo(visibleLimit + 1e-9),
          reason: 'chrome fraction $chrome',
        );
        // Whatever the band does, the marker stays well inside the viewport.
        expect(plan.riderViewportFraction, greaterThan(0.3));
        expect(plan.riderViewportFraction, lessThan(0.95));
      }
    },
  );

  test('the flat fallback bias is a straight ground offset at map scale', () {
    // flutter_map is 2D and 256 pixel tiled, so the bias is simply the pixel
    // offset times its own scale - no perspective term.
    final plan = _plan(29, landscape: false);
    final flat = NavigationCameraPlanner.flatLookAheadMetersFor(
      zoom: plan.zoom,
      forwardBiasPixels: plan.forwardBiasPixels,
      latitudeDegrees: 53,
    );
    final expected =
        plan.forwardBiasPixels *
        156543.03392 *
        math.cos(53 * math.pi / 180) /
        math.pow(2, plan.zoom);
    expect(flat, closeTo(expected, 0.5));
    expect(flat, greaterThan(0));

    // Grows with speed, vanishes without a bias, and follows the bias sign so a
    // marker pushed above centre by a tall chrome band still frames correctly.
    final slow = NavigationCameraPlanner.flatLookAheadMetersFor(
      zoom: _plan(6, landscape: false).zoom,
      forwardBiasPixels: _plan(6, landscape: false).forwardBiasPixels,
      latitudeDegrees: 53,
    );
    expect(slow, lessThan(flat));
    expect(
      NavigationCameraPlanner.flatLookAheadMetersFor(
        zoom: 14,
        forwardBiasPixels: 0,
        latitudeDegrees: 53,
      ),
      0,
    );
    expect(
      NavigationCameraPlanner.flatLookAheadMetersFor(
        zoom: 14,
        forwardBiasPixels: -120,
        latitudeDegrees: 53,
      ),
      lessThan(0),
    );
    expect(
      NavigationCameraPlanner.flatLookAheadMetersFor(
        zoom: 3,
        forwardBiasPixels: 400,
        latitudeDegrees: 53,
      ),
      navigationCameraMaximumLookAheadMeters,
    );
  });

  test('both renderer scales turn the same lateral anchor into a target', () {
    final left = NavigationCameraPlanner.lateralTargetOffsetMetersFor(
      zoom: 14,
      lateralBiasPixels: -140,
      latitudeDegrees: 53,
      tileSize: 512,
    );
    final right = NavigationCameraPlanner.lateralTargetOffsetMetersFor(
      zoom: 14,
      lateralBiasPixels: 140,
      latitudeDegrees: 53,
      tileSize: 512,
    );
    final flutterMap = NavigationCameraPlanner.lateralTargetOffsetMetersFor(
      zoom: 14,
      lateralBiasPixels: -140,
      latitudeDegrees: 53,
      tileSize: 256,
    );

    expect(left, greaterThan(0), reason: 'target moves right of a left anchor');
    expect(right, closeTo(-left, 1e-9));
    expect(flutterMap, closeTo(left * 2, 1e-5));
  });

  group('settledOnViewport', () {
    // The arrival test behind "Follow me" (#141). It answers only "did the camera
    // get to the framing this app commanded", so it scales with zoom rather than
    // fixing a ground distance, and an overview zoom can never pass for a
    // navigation viewport.
    test('scales its tolerance with the zoom, not with a ground distance', () {
      // ~2.3 m per logical pixel at zoom 14.33 on MapLibre's 512 pixel scheme, so
      // the 12 px arrival window is about 28 m.
      expect(
        NavigationCameraPlanner.settledOnViewport(
          driftMeters: 20,
          zoomDelta: 0,
          zoom: 14.33,
          latitudeDegrees: 53,
          tileSize: 512,
        ),
        isTrue,
      );
      expect(
        NavigationCameraPlanner.settledOnViewport(
          driftMeters: 60,
          zoomDelta: 0,
          zoom: 14.33,
          latitudeDegrees: 53,
          tileSize: 512,
        ),
        isFalse,
      );
      // #133's 56 px band called this framed. Measured on an SE, that band was
      // 1363 m at the zoom the phone sat at, so a map panned hundreds of metres
      // off the rider reported itself framed and offered nothing (#141).
      expect(
        NavigationCameraPlanner.settledOnViewport(
          driftMeters: 468,
          zoomDelta: 0,
          zoom: 10.9,
          latitudeDegrees: 51.47,
          tileSize: 512,
        ),
        isFalse,
      );
    });

    test('a route overview never passes for the navigation viewport', () {
      // The camera can be exactly on the commanded ground point and still be the
      // wrong viewport: a whole-route overview is three zoom levels out, showing
      // no road ahead. This is the accident #133's positional test allowed.
      expect(
        NavigationCameraPlanner.settledOnViewport(
          driftMeters: 0,
          zoomDelta: -3.3,
          zoom: 11,
          latitudeDegrees: 53,
          tileSize: 512,
        ),
        isFalse,
      );
      expect(
        NavigationCameraPlanner.settledOnViewport(
          driftMeters: 0,
          zoomDelta: 0.05,
          zoom: 14.33,
          latitudeDegrees: 53,
          tileSize: 512,
        ),
        isTrue,
      );
    });

    test('reads the same drift differently on each tile scheme', () {
      // FlutterMap's 256 pixel scheme is twice the ground scale at the same zoom
      // number, so it tolerates twice the drift. Getting this backwards would
      // make one renderer offer the button constantly and the other never.
      const drift = 40.0;
      expect(
        NavigationCameraPlanner.settledOnViewport(
          driftMeters: drift,
          zoomDelta: 0,
          zoom: 13.87,
          latitudeDegrees: 53,
          tileSize: 256,
        ),
        isTrue,
      );
      expect(
        NavigationCameraPlanner.settledOnViewport(
          driftMeters: drift,
          zoomDelta: 0,
          zoom: 13.87,
          latitudeDegrees: 53,
          tileSize: 512,
        ),
        isFalse,
      );
    });

    test('a camera easing after a moving rider still counts as arrived', () {
      // The window has to clear the ground a bike covers inside one 560 ms camera
      // transition at every riding speed, or the control would flicker back on
      // during ordinary following. The lag stays a handful of pixels because the
      // camera zooms out as the bike speeds up. A deliberate pan is tens of
      // pixels and must never be inside the window.
      for (var speed = 0.0; speed <= 30; speed += 2) {
        for (final landscape in [false, true]) {
          final plan = _plan(speed, landscape: landscape);
          for (final tileSize in [256, 512]) {
            final metresPerPixel =
                (tileSize == 256 ? 156543.03392 : 78271.5169) *
                math.cos(53 * math.pi / 180) /
                math.pow(2, plan.zoom);
            expect(
              NavigationCameraPlanner.settledOnViewport(
                driftMeters: speed * 0.56,
                zoomDelta: 0,
                zoom: plan.zoom,
                latitudeDegrees: 53,
                tileSize: tileSize,
              ),
              isTrue,
              reason: 'a $speed m/s follow lag must still count as arrived',
            );
            expect(
              NavigationCameraPlanner.settledOnViewport(
                driftMeters: 20 * metresPerPixel,
                zoomDelta: 0,
                zoom: plan.zoom,
                latitudeDegrees: 53,
                tileSize: tileSize,
              ),
              isFalse,
              reason: 'a 20 pixel pan at $speed m/s must not read as arrived',
            );
          }
        }
      }
    });

    test('an unmeasurable camera has not arrived', () {
      // #133 read the unknown case as "framed" and hid the control on the strength
      // of it, which is how a MapLibre map that had never reported a camera
      // suppressed the only way back (#141). Unknown is not arrived.
      expect(
        NavigationCameraPlanner.settledOnViewport(
          driftMeters: double.nan,
          zoomDelta: 0,
          zoom: 14,
          latitudeDegrees: 53,
          tileSize: 512,
        ),
        isFalse,
      );
      expect(
        NavigationCameraPlanner.settledOnViewport(
          driftMeters: 4,
          zoomDelta: 0,
          zoom: double.nan,
          latitudeDegrees: 53,
          tileSize: 512,
        ),
        isFalse,
      );
      expect(
        NavigationCameraPlanner.settledOnViewport(
          driftMeters: 4,
          zoomDelta: double.nan,
          zoom: 14,
          latitudeDegrees: 53,
          tileSize: 512,
        ),
        isFalse,
      );
    });
  });

  test('the speed curve is continuous, with no snap at any threshold', () {
    for (final landscape in [false, true]) {
      var previous = _plan(0, landscape: landscape);
      for (var speed = 0.05; speed <= 45; speed += 0.05) {
        final plan = _plan(speed, landscape: landscape);
        expect((plan.zoom - previous.zoom).abs(), lessThan(0.01));
        expect((plan.tilt - previous.tilt).abs(), lessThan(0.05));
        expect(
          (plan.riderViewportFraction - previous.riderViewportFraction).abs(),
          lessThan(0.002),
        );
        expect(
          (plan.lookAheadMeters - previous.lookAheadMeters).abs(),
          lessThan(6),
        );
        previous = plan;
      }
    }
  });
}

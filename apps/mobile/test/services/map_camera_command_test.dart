import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/map_camera_command.dart';

void main() {
  // #359: MapLibre's mbgl::LatLng constructor throws on a coordinate that is
  // not finite or is out of range, and the throw unwinds through Map::flyTo and
  // takes the app with it. A TestFlight crash on 1.0.1 landed exactly there.
  // Nothing between Dart and that constructor catches it, so the check has to
  // happen on this side.
  test('an ordinary camera command is usable', () {
    expect(
      MapCameraCommand.isUsable(
        latitude: 51.4578,
        longitude: -2.4623,
        zoom: 16,
        tilt: 55,
        bearing: 187,
      ),
      isTrue,
    );
  });

  // The follow target is a ground point projected ahead of the rider from the
  // tilt, zoom and measured viewport height. A viewport that has not been laid
  // out reports zero height, and dividing through that geometry is how a NaN
  // reaches the renderer.
  test('a target that is not a number is refused', () {
    expect(
      MapCameraCommand.isUsable(latitude: double.nan, longitude: -2.46),
      isFalse,
    );
    expect(
      MapCameraCommand.isUsable(latitude: 51.45, longitude: double.nan),
      isFalse,
    );
    expect(
      MapCameraCommand.isUsable(latitude: double.infinity, longitude: -2.46),
      isFalse,
    );
  });

  test('a coordinate outside the world is refused', () {
    expect(MapCameraCommand.isUsable(latitude: 91, longitude: 0), isFalse);
    expect(MapCameraCommand.isUsable(latitude: -90.1, longitude: 0), isFalse);
    expect(MapCameraCommand.isUsable(latitude: 0, longitude: 181), isFalse);
    // The poles and the antimeridian are legitimate.
    expect(MapCameraCommand.isUsable(latitude: 90, longitude: 180), isTrue);
    expect(MapCameraCommand.isUsable(latitude: -90, longitude: -180), isTrue);
  });

  // constrainCameraAndZoomToBounds unprojects using the zoom as well as the
  // target, so a non-finite zoom produces an out-of-range latitude just as
  // surely as a non-finite target does. That is the frame the crash report
  // names.
  test('a camera whose zoom, tilt or bearing is not a number is refused', () {
    expect(
      MapCameraCommand.isUsable(
        latitude: 51.45,
        longitude: -2.46,
        zoom: double.nan,
      ),
      isFalse,
    );
    expect(
      MapCameraCommand.isUsable(
        latitude: 51.45,
        longitude: -2.46,
        tilt: double.infinity,
      ),
      isFalse,
    );
    expect(
      MapCameraCommand.isUsable(
        latitude: 51.45,
        longitude: -2.46,
        bearing: double.nan,
      ),
      isFalse,
    );
  });

  // The same throw reaches MapLibre two ways. Device logs from the reporter's
  // phone carry one of each: 28 July 2026 through `Transform::flyTo` from an
  // `animateCamera` with bounds, and 4 August twice through `Transform::easeTo`
  // from the follow camera. Guarding only the target left the bounds open.
  group('bounds', () {
    test('an ordinary box is usable', () {
      expect(
        MapCameraCommand.boundsAreUsable(
          south: 51.44,
          west: -2.47,
          north: 51.47,
          east: -2.44,
        ),
        isTrue,
      );
    });

    test('a corner that is not a number is refused', () {
      expect(
        MapCameraCommand.boundsAreUsable(
          south: double.nan,
          west: -2.47,
          north: 51.47,
          east: -2.44,
        ),
        isFalse,
      );
      expect(
        MapCameraCommand.boundsAreUsable(
          south: 51.44,
          west: -2.47,
          north: double.infinity,
          east: -2.44,
        ),
        isFalse,
      );
    });

    // What a route reduced to one repeated coordinate produces. It is not a
    // frame, and asking the renderer to fit the camera to it is how the zoom
    // goes to infinity and the unprojected latitude leaves the world.
    test('a collapsed or inverted box is refused', () {
      expect(
        MapCameraCommand.boundsAreUsable(
          south: 51.45,
          west: -2.46,
          north: 51.45,
          east: -2.46,
        ),
        isFalse,
      );
      expect(
        MapCameraCommand.boundsAreUsable(
          south: 51.47,
          west: -2.44,
          north: 51.44,
          east: -2.47,
        ),
        isFalse,
      );
    });
  });
}

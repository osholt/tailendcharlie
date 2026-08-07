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
}

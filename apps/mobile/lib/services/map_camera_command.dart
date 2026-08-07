/// Whether a camera command is safe to hand to the map renderer.
///
/// MapLibre's `mbgl::LatLng` constructor **throws** on a coordinate that is not
/// finite or is out of range, and nothing between Dart and that constructor
/// catches it: the throw unwinds through `Map::flyTo` and takes the app with it.
/// A TestFlight crash on 1.0.1 landed exactly there —
/// `mbgl::LatLng::LatLng` ← `Projection::unproject` ←
/// `TransformState::constrainCameraAndZoomToBounds` ← `Transform::flyTo` ←
/// `MLNMapView flyToCamera:` ← `MapLibreMapController.onMethodCall` (#359).
///
/// So the coordinate is checked on this side, where a bad value can be dropped
/// instead of crashing a rider's phone mid-ride.
///
/// The follow camera is the likely source. Its target is a ground point
/// projected ahead of the rider from the tilt, zoom and measured viewport
/// height, and a viewport height of zero - which is what a map that has not been
/// laid out reports, including while another scene is connecting - divides
/// through that geometry. Zoom, tilt and bearing are checked for the same
/// reason: `constrainCameraAndZoomToBounds` unprojects using all of them, so a
/// non-finite zoom produces an out-of-range latitude just as surely as a
/// non-finite target does.
library;

class MapCameraCommand {
  const MapCameraCommand._();

  /// True when every value is finite and inside the range the renderer accepts.
  ///
  /// Deliberately not clamped. A camera aimed at a clamped guess of where the
  /// rider might be is a map quietly pointing somewhere wrong, which on a
  /// riding surface is worse than a frame that does not move: the next position
  /// fix issues another command a fraction of a second later, so a dropped one
  /// costs nothing a rider can see.
  static bool isUsable({
    required double latitude,
    required double longitude,
    double? zoom,
    double? tilt,
    double? bearing,
  }) {
    if (!_finite(latitude) || !_finite(longitude)) return false;
    if (latitude < -90 || latitude > 90) return false;
    if (longitude < -180 || longitude > 180) return false;
    for (final value in [zoom, tilt, bearing]) {
      if (value != null && !_finite(value)) return false;
    }
    return true;
  }

  static bool _finite(double value) => !value.isNaN && !value.isInfinite;
}

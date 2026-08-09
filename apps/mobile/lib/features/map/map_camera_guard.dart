import 'package:maplibre_gl/maplibre_gl.dart' as ml;

import '../../services/map_camera_command.dart';

/// [MapCameraCommand] in the renderer's own types.
///
/// The rule itself is renderer-agnostic and stays that way, in
/// `map_camera_command.dart`. This is only the adapter, kept in one place
/// because the throw it prevents is reached from several screens and guarding
/// some of them is the same as guarding none: #377 covered the follow camera,
/// #385 covered the ride map's bounds, and the ride history, the route preview
/// and the group mini-map were still handing values straight to it.
extension MapLibreCameraGuard on ml.LatLngBounds {
  /// True when this box is one the renderer can frame.
  ///
  /// A ride whose points are a single repeated coordinate - a phone that never
  /// got a second fix - collapses to a box with no width, which is refused here
  /// rather than aborting the process inside `constrainCameraAndZoomToBounds`.
  bool get isUsableCamera => MapCameraCommand.boundsAreUsable(
    south: southwest.latitude,
    west: southwest.longitude,
    north: northeast.latitude,
    east: northeast.longitude,
  );
}

/// True when a point and zoom are safe to hand to the renderer.
///
/// The range half of the check reads as redundant here and is not: `ml.LatLng`
/// clamps an out-of-range latitude at the Dart boundary, so an overshoot cannot
/// reach the renderer through this type, but **NaN passes straight through it**
/// and is what reaches `mbgl::LatLng` and throws.
bool mapLibreCameraIsUsable(ml.LatLng target, {double? zoom}) =>
    MapCameraCommand.isUsable(
      latitude: target.latitude,
      longitude: target.longitude,
      zoom: zoom,
    );

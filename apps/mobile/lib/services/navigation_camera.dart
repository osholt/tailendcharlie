class NavigationCameraPlan {
  const NavigationCameraPlan({required this.zoom, required this.tilt});

  final double zoom;
  final double tilt;
}

/// Converts a smoothed road speed into a restrained navigation camera.
///
/// The continuous curve avoids abrupt zoom jumps at arbitrary speed bands.
/// Higher speeds expose more road ahead with a wider zoom and slightly steeper
/// tilt; landscape remains wider to preserve controls at the screen edges.
abstract final class NavigationCameraPlanner {
  static NavigationCameraPlan plan({
    required double? speedMetersPerSecond,
    required bool landscape,
  }) {
    final speed = (speedMetersPerSecond ?? 0).isFinite
        ? (speedMetersPerSecond ?? 0).clamp(0.0, 32.0)
        : 0.0;
    final speedFactor = speed / 32;
    final baseZoom = landscape ? 14.15 : 14.65;
    final baseTilt = landscape ? 52.0 : 48.0;
    return NavigationCameraPlan(
      zoom: baseZoom - 0.8 * speedFactor,
      tilt: baseTilt + 8 * speedFactor,
    );
  }
}

import 'dart:math' as math;

/// MapLibre's perspective camera uses a fixed vertical field of view of
/// 36.87 degrees on every platform, so the camera sits
/// `0.5 * viewportHeight / tan(fov / 2)` pixels away from the point it is
/// aimed at. The forward-bias geometry below depends on that relationship.
const double _cameraFieldOfViewRadians = 0.6435011087932844;

/// MapLibre Native clamps the camera pitch to 60 degrees on both Android and
/// iOS. Planning up to 58 degrees keeps a small margin so the plan is never
/// silently clamped, which would otherwise make the eased transition end
/// somewhere other than where it was asked to.
const double navigationCameraMaximumTiltDegrees = 58;

/// Above this speed the framing stops opening up. More speed does not keep
/// pushing the horizon away; it only makes the near field unreadable.
const double navigationCameraFramingTopSpeedMetersPerSecond = 30;

/// Vertical position of the rider in the map viewport, as a fraction of the
/// viewport height measured from the top edge. 0.5 is dead centre, which is
/// what a plain map does; a navigation view puts the rider low so most of the
/// screen shows the road ahead.
const double navigationCameraRestRiderFractionPortrait = 0.56;
const double navigationCameraFastRiderFractionPortrait = 0.70;
const double navigationCameraRestRiderFractionLandscape = 0.58;
const double navigationCameraFastRiderFractionLandscape = 0.72;

/// Space kept between the rider's marker and the top of the bottom chrome
/// band, as a fraction of the viewport height. The marker is 38 logical
/// pixels tall, so this leaves its full height plus a margin clear on an
/// 800 pixel viewport.
const double navigationCameraRiderChromeClearanceFraction = 0.06;

/// How high in the frame the rider may be pushed when a very tall chrome band
/// would otherwise cover the centre of the viewport. Keeping the marker visible
/// beats keeping the forward bias, so the framing gives up the bias - and, past
/// this point, some of the road behind - rather than hiding the rider.
const double navigationCameraMinimumRiderFraction = 0.35;

/// The look-ahead the camera is allowed to aim at, whatever the tilt and zoom
/// geometry asks for. A bounded value keeps a mis-measured viewport or an
/// unusually shallow latitude from throwing the camera kilometres up the road.
const double navigationCameraMaximumLookAheadMeters = 1200;

/// A camera framing for one ride update.
class NavigationCameraPlan {
  const NavigationCameraPlan({
    required this.zoom,
    required this.tilt,
    required this.riderViewportFraction,
    required this.forwardBiasPixels,
    required this.lookAheadMeters,
  });

  final double zoom;
  final double tilt;

  /// Where the rider's own marker sits vertically in the map viewport, as a
  /// fraction of its height from the top edge. Always at or below the centre.
  final double riderViewportFraction;

  /// Logical pixels between the viewport centre and the rider's marker.
  /// Negative when the marker sits above the centre.
  ///
  /// This is the input to both look-ahead conversions rather than something to
  /// hand a map as a screen-space offset: neither map implementation applies
  /// such an offset reliably, so the bias is always baked into the camera
  /// target. See [lookAheadMeters] and
  /// [NavigationCameraPlanner.flatLookAheadMetersFor].
  final double forwardBiasPixels;

  /// Ground distance from the rider to the point the camera is aimed at.
  ///
  /// `maplibre_gl` 0.26 exposes no camera padding or anchor, so the forward
  /// bias is applied by aiming the camera at a point this far ahead along the
  /// current bearing. The distance is derived from the tilt, zoom and viewport
  /// geometry, so the rider lands at [riderViewportFraction] by construction
  /// rather than by guessing a look-ahead distance.
  final double lookAheadMeters;
}

/// Converts a smoothed road speed into a forward-looking navigation camera.
///
/// The framing is driven by one normalised speed curve so zoom, tilt and
/// forward bias move together. The curve is a smoothstep, so its value *and*
/// its gradient are continuous at both ends: nothing snaps when the rider
/// crosses a speed threshold, and the framing simply stops changing above
/// [navigationCameraFramingTopSpeedMetersPerSecond].
///
/// Tilt is deliberately steep. At 51-58 degrees the ground plane compresses
/// towards a visible horizon in the upper part of the frame, which is what
/// makes the view read as looking along the road rather than down at a map.
/// Landscape starts steeper because its viewport is short, so the same tilt
/// shows less distance.
abstract final class NavigationCameraPlanner {
  static NavigationCameraPlan plan({
    required double? speedMetersPerSecond,
    required bool landscape,
    double viewportHeightPixels = 800,
    double latitudeDegrees = 51.5,
    double bottomChromeFraction = 0,
  }) {
    final speed = (speedMetersPerSecond ?? 0).isFinite
        ? (speedMetersPerSecond ?? 0).clamp(
            0.0,
            navigationCameraFramingTopSpeedMetersPerSecond,
          )
        : 0.0;
    final normalised = speed / navigationCameraFramingTopSpeedMetersPerSecond;
    // Smoothstep: zero gradient at rest and at the top of the curve.
    final speedFactor = normalised * normalised * (3 - 2 * normalised);
    final baseZoom = landscape ? 14.15 : 14.65;
    final baseTilt = landscape ? 53.0 : 51.0;
    final zoom = baseZoom - 0.8 * speedFactor;
    final tilt =
        baseTilt +
        (navigationCameraMaximumTiltDegrees - baseTilt) * speedFactor;
    final height = viewportHeightPixels.isFinite && viewportHeightPixels > 0
        ? viewportHeightPixels
        : 800.0;
    final riderFraction = _riderViewportFraction(
      landscape: landscape,
      speedFactor: speedFactor,
      bottomChromeFraction: bottomChromeFraction,
    );
    final forwardBiasPixels = (riderFraction - 0.5) * height;
    return NavigationCameraPlan(
      zoom: zoom,
      tilt: tilt,
      riderViewportFraction: riderFraction,
      forwardBiasPixels: forwardBiasPixels,
      lookAheadMeters: lookAheadMetersFor(
        tiltDegrees: tilt,
        zoom: zoom,
        forwardBiasPixels: forwardBiasPixels,
        viewportHeightPixels: height,
        latitudeDegrees: latitudeDegrees,
      ),
    );
  }

  /// The rider's vertical position, biased forward with speed and then pulled
  /// back far enough to keep the marker clear of the bottom chrome band.
  ///
  /// [bottomChromeFraction] is the share of the viewport height occupied by
  /// overlays directly below the rider. Portrait chrome sits in a bottom band
  /// under the marker, so it constrains the bias; landscape chrome lives in
  /// side rails that the centred marker never reaches, so callers pass zero.
  static double _riderViewportFraction({
    required bool landscape,
    required double speedFactor,
    required double bottomChromeFraction,
  }) {
    final rest = landscape
        ? navigationCameraRestRiderFractionLandscape
        : navigationCameraRestRiderFractionPortrait;
    final fast = landscape
        ? navigationCameraFastRiderFractionLandscape
        : navigationCameraFastRiderFractionPortrait;
    final preferred = rest + (fast - rest) * speedFactor;
    final chrome = bottomChromeFraction.isFinite
        ? bottomChromeFraction.clamp(0.0, 1.0)
        : 0.0;
    final allowed = 1 - chrome - navigationCameraRiderChromeClearanceFraction;
    return math.max(
      navigationCameraMinimumRiderFraction,
      math.min(preferred, allowed),
    );
  }

  /// Ground distance from the rider to the camera target that places the rider
  /// [forwardBiasPixels] below the viewport centre. Negative when the bias is
  /// negative, which only happens when a very tall chrome band has pushed the
  /// marker above the centre of the frame.
  ///
  /// The camera sits `d = 0.5 * height / tan(fov / 2)` pixels from the target
  /// at a pitch of `tilt` from the nadir, so its height above the ground plane
  /// is `d * cos(tilt)`. A screen point [forwardBiasPixels] below the centre is
  /// seen along a ray `atan(bias / d)` shallower than the centre ray, so the
  /// ground distance between the two is
  /// `d * cos(tilt) * (tan(tilt) - tan(tilt - rayAngle))` in ground pixels,
  /// which the Web Mercator scale converts to metres.
  static double lookAheadMetersFor({
    required double tiltDegrees,
    required double zoom,
    required double forwardBiasPixels,
    required double viewportHeightPixels,
    required double latitudeDegrees,
  }) {
    if (forwardBiasPixels == 0 ||
        viewportHeightPixels <= 0 ||
        !forwardBiasPixels.isFinite ||
        !viewportHeightPixels.isFinite) {
      return 0;
    }
    final cameraToCentrePixels =
        0.5 * viewportHeightPixels / math.tan(_cameraFieldOfViewRadians / 2);
    final tilt = tiltDegrees * math.pi / 180;
    final rayAngle = math.atan(forwardBiasPixels / cameraToCentrePixels);
    final groundPixels =
        cameraToCentrePixels *
        math.cos(tilt) *
        (math.tan(tilt) - math.tan(tilt - rayAngle));
    final metres = groundPixels * _metersPerPixel(zoom, latitudeDegrees);
    if (!metres.isFinite) return 0;
    return metres.clamp(
      -navigationCameraMaximumLookAheadMeters,
      navigationCameraMaximumLookAheadMeters,
    );
  }

  /// Ground distance from the rider to the camera target for a flat, untilted
  /// map.
  ///
  /// `flutter_map` is 2D, so the bias is a straight ground offset at the map's
  /// own scale rather than the perspective geometry [lookAheadMetersFor]
  /// solves. It has to be baked into the camera target: passing it as
  /// `moveAndRotateAnimatedRaw`'s screen-space `offset` does not survive, since
  /// that method delegates to `moveAnimatedRaw` *without* forwarding the offset
  /// whenever the new bearing equals the current one — which the rotation
  /// deadband makes the common case. The camera would then flip between biased
  /// and centred framing as the bearing came in and out of the deadband.
  static double flatLookAheadMetersFor({
    required double zoom,
    required double forwardBiasPixels,
    required double latitudeDegrees,
  }) {
    if (forwardBiasPixels == 0 || !forwardBiasPixels.isFinite) return 0;
    final metres =
        forwardBiasPixels *
        _metersPerPixel(zoom, latitudeDegrees, tileSize: 256);
    if (!metres.isFinite) return 0;
    return metres.clamp(
      -navigationCameraMaximumLookAheadMeters,
      navigationCameraMaximumLookAheadMeters,
    );
  }

  /// Ground metres per logical pixel. MapLibre uses a 512 pixel tile scheme,
  /// `flutter_map` a 256 pixel one, so the same zoom number is a different
  /// scale on each.
  static double _metersPerPixel(
    double zoom,
    double latitudeDegrees, {
    int tileSize = 512,
  }) =>
      (tileSize == 256 ? 156543.03392 : 78271.5169) *
      math.cos(latitudeDegrees * math.pi / 180).abs() /
      math.pow(2, zoom);
}

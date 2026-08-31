import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../domain/imported_route.dart' show GeoPoint;

/// Where the group mini-map should point, and how far out.
///
/// The framing used to be handed to MapLibre's `newLatLngBounds` and the result
/// was not something any test could see - the mini-map is MapLibre-only, so no
/// widget test exercises it, which is how it reached a rider framed on open sea:
///
/// > My mini map is somewhere in North Wales, with none of us in it.
///
/// One rider was on the Isle of Man and the rest near Bristol, about 300 km
/// apart, and the mini-map showed neither end. Computing the camera here instead
/// makes the decision testable, and removes the dependence on how a bounds fit
/// behaves in a 150 x 104 box (#172).
@immutable
class GroupMiniMapFraming {
  const GroupMiniMapFraming({
    required this.centre,
    required this.zoom,
    required this.spanMeters,
  });

  final GeoPoint centre;

  /// Web Mercator zoom, clamped to [minimumZoom].
  final double zoom;

  /// The greatest distance between any two framed riders, in metres. What the
  /// scale indicator reports, so a glance answers "how spread out are we" -
  /// half a mile, four miles or 195 miles, the case a tester named the "K-Lo
  /// edge case".
  final double spanMeters;

  /// A lone rider gets a street-level view; there is no spread to show.
  static const singleRiderZoom = 14.5;

  /// Used when only one rider can be placed but the group is known to be larger.
  ///
  /// The rider count comes from the roster, while the framing only receives
  /// riders the map can actually place, so the two disagree whenever someone has
  /// joined but their first position has not arrived. Framing at
  /// [singleRiderZoom] then reads as a street map of one rider while the caption
  /// says two - which is what a tester photographed: "2 RIDERS", no markers, and
  /// a 200 m scale bar (#172).
  ///
  /// Chosen for the *shorter* axis: at UK latitudes this covers roughly 6 km
  /// vertically in the portrait mini-map, so a rider a few kilometres away is
  /// already inside the viewport when their first position arrives, rather than
  /// depending on a refit to become visible. Erring wide is right here because
  /// the state is temporary - the ordinary bounds fit takes over the moment there
  /// are two points to fit.
  static const awaitingOtherRidersZoom = 10.0;

  /// Web Mercator bottoms out at 0, where the whole world is 256 px wide. No
  /// group on one planet needs further out than this, so the framing never has
  /// to admit defeat - which is what the old behaviour effectively did by
  /// pointing at the midpoint and showing nobody.
  static const minimumZoom = 0.0;

  /// Never closer than this even for a tight group, so the mini-map stays a
  /// group overview rather than becoming a second navigation map.
  static const maximumZoom = 15.0;

  /// The world size used by the renderer-independent framing calculation.
  static const referenceTileSize = 256.0;

  /// MapLibre Native's world is 512 logical pixels wide at zoom 0. Supplying a
  /// zoom calculated for a 256 px world makes the same rider spread twice as
  /// wide on iOS, consuming the intended margin and clipping edge markers.
  static const mapLibreNativeTileSize = 512.0;

  /// Metres of ground per logical pixel at the equator, zoom 0. The standard
  /// Web Mercator constant, and what makes the arithmetic below check out
  /// against a scale bar.
  static const equatorMetersPerPixelAtZoomZero = 156543.03392;

  /// Frames every point, however far apart they are.
  ///
  /// [width] and [height] are the *usable* pixels - the caller subtracts its own
  /// padding first, because padding that exceeds the box is one of the ways the
  /// old fit produced nonsense.
  /// [awaitingOtherRiders] is true when the roster holds riders the map cannot
  /// place yet. It only affects the single-point case, where it is the difference
  /// between "this rider is alone" and "this is the only rider we can draw".
  factory GroupMiniMapFraming.forPoints(
    List<GeoPoint> points, {
    required double width,
    required double height,
    bool awaitingOtherRiders = false,
  }) {
    assert(points.isNotEmpty, 'Framing needs at least one point');
    if (points.length == 1) {
      return GroupMiniMapFraming(
        centre: points.single,
        zoom: awaitingOtherRiders ? awaitingOtherRidersZoom : singleRiderZoom,
        spanMeters: 0,
      );
    }
    var minimumLatitude = points.first.latitude;
    var maximumLatitude = points.first.latitude;
    var minimumLongitude = points.first.longitude;
    var maximumLongitude = points.first.longitude;
    for (final point in points.skip(1)) {
      minimumLatitude = math.min(minimumLatitude, point.latitude);
      maximumLatitude = math.max(maximumLatitude, point.latitude);
      minimumLongitude = math.min(minimumLongitude, point.longitude);
      maximumLongitude = math.max(maximumLongitude, point.longitude);
    }
    // Mercator stretches north-south with latitude, so both the centre and the
    // span are computed in projected units rather than degrees. The midpoint of
    // two latitudes is *not* their average once the span is large - centring on
    // the average put the northern rider outside a viewport the arithmetic said
    // would hold both, which a 900 km test case caught.
    final topY = _mercatorY(maximumLatitude);
    final bottomY = _mercatorY(minimumLatitude);
    final centre = GeoPoint(
      latitude: _latitudeAtMercatorY((topY + bottomY) / 2),
      longitude: (minimumLongitude + maximumLongitude) / 2,
    );
    final verticalSpan = (topY - bottomY).abs();
    final horizontalSpan = ((maximumLongitude - minimumLongitude).abs() / 360)
        .clamp(0.0, 1.0);

    final zoomForWidth = _zoomForFraction(horizontalSpan, width);
    final zoomForHeight = _zoomForFraction(verticalSpan, height);
    final zoom = math
        .min(zoomForWidth, zoomForHeight)
        .clamp(minimumZoom, maximumZoom);

    return GroupMiniMapFraming(
      centre: centre,
      zoom: zoom,
      spanMeters: _widestSeparationMeters(points),
    );
  }

  /// Metres per logical pixel at [centre] and [zoom] - what a scale bar needs.
  double get metersPerPixel =>
      equatorMetersPerPixelAtZoomZero *
      math.cos(centre.latitude * math.pi / 180).abs() /
      math.pow(2, zoom);

  /// Converts the reference zoom to a renderer with a different zoom-0 world
  /// size while preserving the exact geographic viewport.
  double zoomForTileSize(double tileSize) {
    if (!tileSize.isFinite || tileSize <= 0) return zoom;
    return (zoom + math.log(referenceTileSize / tileSize) / math.ln2).clamp(
      minimumZoom,
      maximumZoom,
    );
  }

  /// The zoom at which [fraction] of the world fills [pixels].
  ///
  /// A degenerate span - every rider on the same spot in one axis - must not
  /// drive the zoom, so it yields the closest allowed view and lets the other
  /// axis decide.
  static double _zoomForFraction(double fraction, double pixels) {
    if (fraction <= 0 || pixels <= 0) return maximumZoom;
    // referenceTileSize * 2^z pixels spans the world, so the projected fraction
    // at that zoom must fit in `pixels`.
    return math.log(pixels / (fraction * referenceTileSize)) / math.ln2;
  }

  /// The latitude at normalised Mercator [y] - the inverse of [_mercatorY].
  static double _latitudeAtMercatorY(double y) {
    final radians = math.atan(_sinh(math.pi * (1 - 2 * y)));
    return radians * 180 / math.pi;
  }

  static double _sinh(double value) => (math.exp(value) - math.exp(-value)) / 2;

  /// Normalised Mercator y in 0..1, north to south.
  static double _mercatorY(double latitude) {
    final clamped = latitude.clamp(-85.05112878, 85.05112878);
    final radians = clamped * math.pi / 180;
    return (1 - math.log(math.tan(radians) + 1 / math.cos(radians)) / math.pi) /
        2;
  }

  static double _widestSeparationMeters(List<GeoPoint> points) {
    var widest = 0.0;
    for (var first = 0; first < points.length - 1; first += 1) {
      for (var second = first + 1; second < points.length; second += 1) {
        final separation = _distanceMeters(points[first], points[second]);
        if (separation > widest) widest = separation;
      }
    }
    return widest;
  }

  static double _distanceMeters(GeoPoint first, GeoPoint second) {
    const earthRadius = 6371008.8;
    final latitude1 = first.latitude * math.pi / 180;
    final latitude2 = second.latitude * math.pi / 180;
    final deltaLatitude = latitude2 - latitude1;
    final deltaLongitude = (second.longitude - first.longitude) * math.pi / 180;
    final a =
        math.pow(math.sin(deltaLatitude / 2), 2) +
        math.cos(latitude1) *
            math.cos(latitude2) *
            math.pow(math.sin(deltaLongitude / 2), 2);
    return earthRadius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
}

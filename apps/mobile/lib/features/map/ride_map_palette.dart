import 'package:flutter/painting.dart';

import 'route_trail_style.dart';

/// Every colour a marker or line on the ride map is drawn in, resolved in one
/// place for the main map and the group overview (#844).
///
/// The two maps are drawn by different code - flutter_map on iOS, MapLibre on
/// Android, and three renderers for the overview - and each used to carry its
/// own copy of the colours. They had drifted: the overview painted the local
/// rider orange whatever colour they had chosen, and outlined everyone in white
/// where the main map used a dark edge, so a rider could not match a marker on
/// one map to the same bike on the other. Both now ask here.
///
/// The line colours stay in [RouteTrailStyle], which owns the measured contrast
/// of every one of them; [lineStyle] is the single way to look one up.
abstract final class RideMapPalette {
  /// A rider's marker fill. Always their own identity colour: a role or an alert
  /// is shown by the marker's shape and label, never by replacing it (#250).
  static Color riderFill(Color identity) => identity;

  /// The edge round a marker. Other riders get the dark casing every route line
  /// has, which is what makes a light fill findable on any basemap; the local
  /// rider gets a white edge so "you" reads at a glance on both maps.
  static Color riderOutline({required bool local}) =>
      local ? localRiderOutline : otherRiderOutline;

  /// See [riderOutline].
  static const Color otherRiderOutline = RouteTrailStyle.casing;

  /// See [riderOutline].
  static const Color localRiderOutline = Color(0xFFFFFFFF);

  /// [otherRiderOutline] and [localRiderOutline] as MapLibre paint strings;
  /// asserted to match in tests.
  static const String otherRiderOutlineHex = RouteTrailStyle.casingHex;
  static const String localRiderOutlineHex = '#FFFFFF';

  /// Ink for the bike glyph inside a marker badge.
  static const Color glyphInk = RouteTrailStyle.markerGlyph;

  /// How [line] is drawn on the main map, or on the group overview when
  /// [overview] is true. The overview draws only the route ahead and the
  /// leader's trail, and returns null for every other line.
  ///
  /// The colour is the same on both maps by construction: the overview's styles
  /// differ from the main map's only in weight.
  static RouteLineStyle? lineStyle(RideMapLine line, {bool overview = false}) {
    if (!overview) {
      return switch (line) {
        RideMapLine.remainingRoute => RouteTrailStyle.routeAhead,
        RideMapLine.riddenRoute => RouteTrailStyle.travelled,
        _ => RouteTrailStyle.forTrail(line.trailKind!),
      };
    }
    return switch (line) {
      RideMapLine.remainingRoute => RouteTrailStyle.miniMapRoute,
      RideMapLine.leaderTrail => RouteTrailStyle.miniMapLeaderTrail,
      _ => null,
    };
  }
}

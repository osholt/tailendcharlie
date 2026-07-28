import 'dart:math' as math;
import 'dart:ui';

import '../../services/rider_trail_recorder.dart';

/// One route or trail line, described once for every renderer.
///
/// [widthPixels] and [casingWidthPixels] are logical pixels so the MapLibre
/// line layers, the flutter_map polyline fallback and the locally painted
/// mini-map cannot drift apart. [dashPixels] is the on/off run length in the
/// same units, or null for a solid line.
class RouteLineStyle {
  const RouteLineStyle({
    required this.color,
    required this.widthPixels,
    required this.casingWidthPixels,
    this.dashPixels,
  });

  final Color color;
  final double widthPixels;
  final double casingWidthPixels;
  final List<double>? dashPixels;

  bool get isDashed => dashPixels != null;

  /// MapLibre expresses `line-dasharray` in multiples of the line width, so the
  /// pixel run lengths are converted here rather than being restated per layer.
  List<double>? get maplibreDashArray => _dashArrayFor(widthPixels);

  /// The same dash run lengths for the casing layer, which is wider and so
  /// needs a different multiplier to keep its dashes aligned with the line's.
  List<double>? get maplibreCasingDashArray => _dashArrayFor(casingWidthPixels);

  /// Extra width the flutter_map fallback adds around the line: its
  /// `borderStrokeWidth` is added to the stroke width rather than replacing it.
  double get fallbackBorderWidthPixels => casingWidthPixels - widthPixels;

  List<double>? _dashArrayFor(double width) =>
      dashPixels?.map((value) => value / width).toList(growable: false);
}

/// Colour, weight and pattern for every kind of route and trail geometry on the
/// ride map, plus the measurements that justify them.
///
/// The route ahead was `#3478F6` at width 5, dotted, drawn at 90% opacity. Its
/// measured luminance contrast against the dark basemap this app renders is
/// only 1.80:1 over a motorway fill and 4.53:1 at best, which is why a tester
/// reported it as too faint to see through a visor in sunlight (#107). Dotting
/// reduced its effective area further, and the alpha reduced it again.
///
/// Contrast is now solved along two independent axes:
///
/// 1. Luminance against the basemap. Every line is opaque, bright, and carries
///    an opaque near-black casing. The bright fill provides the contrast over a
///    dark basemap, the casing provides it over a light one.
/// 2. Weight and pattern. Five bright colours cannot all be separated by
///    luminance alone - a dark basemap needs every one of them to be light - so
///    each category also has a unique (width, dash pattern) pair and stays
///    identifiable in a greyscale render.
///
/// Measured WCAG contrast ratios (see `route_trail_style_test.dart`, which
/// asserts them):
///
/// | line          | colour  | dark worst | dark typical | vs casing |
/// |---------------|---------|-----------:|-------------:|----------:|
/// | route ahead   | #3DDC84 |      4.11  |        9.54  |    10.27  |
/// | travelled     | #FF7A1A |      2.81  |        6.52  |     7.02  |
/// | leader trail  | #D3B8FF |      4.22  |        9.78  |    10.53  |
/// | off route     | #FF5FD1 |      2.73  |        6.33  |     6.81  |
/// | rejoin        | #00E5FF |      4.77  |       11.06  |    11.91  |
///
/// "dark worst" is against the lightest surface of the dark basemap (the
/// motorway fill), "dark typical" against its background. The casing measures
/// 16.74:1 against the light basemap's background and 18.32:1 against its white
/// road fills, which is what keeps the same bright colours legible in daylight.
///
/// The travelled orange is unchanged: the same field report called it "quite
/// visible", so it is the reference the other lines are held against rather
/// than something to re-tune.
///
/// The closest pair by luminance alone is the route ahead against the rejoin
/// breadcrumb (1.16) and against the leader trail (1.03). Hue separates the
/// first, and both are separated by width and pattern: 6px long-dash for the
/// route ahead, 4.5px dash for the rejoin, 8px solid for the leader trail.
class RouteTrailStyle {
  const RouteTrailStyle._();

  /// Opaque casing drawn under every route and trail line.
  static const casing = Color(0xFF10151C);

  /// [casing] as a MapLibre paint string; asserted to match in tests.
  static const casingHex = '#10151C';

  /// Ink for the symbol drawn *inside* a marker badge - the motorcycle glyph on
  /// a rider, the warning glyph on a hazard.
  ///
  /// The same dark ink as [casing], and for the same reason: every badge fill is
  /// deliberately light, because it has to be found on a dark basemap. A white
  /// glyph on a light badge is the one ink on this map with nothing behind it,
  /// and #133 measured it at 1.53:1 on the caution yellow, 1.76:1 on the default
  /// rider green, and never better than 3.87:1 on any badge in the palette - so
  /// the marker that says *which rider* and *how bad* was the least legible
  /// thing on the surface, while the route lines #107 fixed were fine.
  ///
  /// Dark ink reverses it: 4.74:1 at worst (the rider's own blue badge) and
  /// 12.00:1 on the caution yellow. Every badge colour in the app measures
  /// better this way than with white - there is no case where white wins - so
  /// this is a fixed colour rather than a per-badge choice.
  static const markerGlyph = casing;

  /// [markerGlyph] as a MapLibre paint string.
  static const markerGlyphHex = casingHex;

  /// Green rather than cyan: cyan belongs to the rejoin breadcrumb (#102), and
  /// the route ahead and a live rejoin appear together, so those two must not be
  /// the pair that looks alike. Green also survives the light basemap, whose road
  /// fills are white and cream - a yellow or amber route line would disappear
  /// into the `#FFEEAA` trunk-road fill it is drawn on.
  static const _plannedRouteColor = Color(0xFF3DDC84);

  /// The planned route that has not been ridden yet.
  static const routeAhead = RouteLineStyle(
    color: _plannedRouteColor,
    widthPixels: 6,
    casingWidthPixels: 10,
    // Long dashes with short gaps: the route ahead stays distinguishable from
    // the solid travelled trail while still reading as a continuous line at
    // navigation zoom, which the previous 0.5px dots did not.
    dashPixels: [22, 11],
  );

  /// The planned route already covered, and the local rider's own trail. Both
  /// mean "where we have been", so they share one colour and overlap harmlessly
  /// when the rider is on route.
  static const travelled = RouteLineStyle(
    color: Color(0xFFFF7A1A),
    widthPixels: 5,
    casingWidthPixels: 9,
  );

  /// The leader's travelled path: the group's ground truth once the plan stops
  /// matching the road, so it is the widest line on the map and is drawn under
  /// the planned route rather than over it.
  static const leaderTrail = RouteLineStyle(
    color: Color(0xFFD3B8FF),
    widthPixels: 8,
    casingWidthPixels: 12,
  );

  /// A rider flagged as suspected off route, off route, or recovering.
  static const offRouteTrail = RouteLineStyle(
    color: Color(0xFFFF5FD1),
    widthPixels: 4,
    casingWidthPixels: 8,
    dashPixels: [9, 7],
  );

  /// The live rejoin route from off-route rerouting (#102), which claimed this
  /// cyan and renders it dashed. Declared here so the palette stays one table
  /// and the widths and dash runs stay distinct from every other line.
  ///
  /// Now slotted in fully: [RiderTrailKind.rejoin] maps to it in [forTrail],
  /// and - because MapLibre cannot data-drive `line-dasharray` - it gets its own
  /// dashed line layer from the same per-kind layer builder every other trail
  /// uses.
  static const rejoinBreadcrumb = RouteLineStyle(
    color: Color(0xFF00E5FF),
    widthPixels: 4.5,
    casingWidthPixels: 8.5,
    dashPixels: [12, 8],
  );

  /// The compact group overview shows the whole planned route at a glance;
  /// dashes at that size read as noise, so it uses the route-ahead colour
  /// solid.
  static const miniMapRoute = RouteLineStyle(
    color: _plannedRouteColor,
    widthPixels: 3,
    casingWidthPixels: 5,
  );

  static RouteLineStyle forTrail(RiderTrailKind kind) => switch (kind) {
    RiderTrailKind.rider => travelled,
    RiderTrailKind.leader => leaderTrail,
    RiderTrailKind.offRoute => offRouteTrail,
    RiderTrailKind.rejoin => rejoinBreadcrumb,
  };

  /// Every badge fill a marker glyph is drawn on, so one test can hold the whole
  /// set against [markerGlyph] rather than each caller asserting its own.
  ///
  /// Anything that adds a new badge - #135's reported camera and police symbols,
  /// for one - belongs in here, so the glyph rule is checked against it too.
  ///
  /// #135 added the three enforcement rows. All three are the same near-white
  /// plate at a different stage of its life: `HazardMapSymbols` blends an ageing
  /// report toward grey rather than making it translucent, precisely so the faded
  /// steps land in this table and have to satisfy the same rule as everything
  /// else. That is what stops the fade being taken too far - the fading step
  /// still measures 8.99:1 against its own ring, and it is why the blend target
  /// is a lighter grey than the one a stale rider marker uses. The road-defect
  /// fills are the four `hazard *` rows below, unchanged, and their faded steps
  /// are generated and checked in `hazard_map_symbol_test.dart` rather than
  /// listed here.
  static const markerBadgeFills = <String, Color>{
    'own rider': Color(0xFF2F80ED),
    // #135. Near-white is the one value nothing else on this map uses, and at
    // 17.04:1 against its own ring it is also the most findable badge in the set,
    // which is what a camera or a police sighting warrants.
    'enforcement report': Color(0xFFF4F7FA),
    'enforcement report ageing': Color(0xFFCCD3DA),
    'enforcement report fading': Color(0xFFACB7C2),
    'rider green': Color(0xFF6ED89A),
    'rider orange': Color(0xFFFF9F5A),
    'rider yellow': Color(0xFFE8D24C),
    'rider teal': Color(0xFF4FC7C7),
    'rider pink': Color(0xFFE87FC0),
    'rider cyan': Color(0xFF5AC8FA),
    'rider amber': Color(0xFFD9A441),
    'rider crimson': Color(0xFFD9607A),
    'lead role': Color(0xFFB58CFF),
    'tail end charlie role': Color(0xFF68A9FF),
    'alerting rider': Color(0xFFFF5D73),
    'hazard advisory': Color(0xFF8EA7C4),
    'hazard caution': Color(0xFFFFC857),
    'hazard serious': Color(0xFFFF8A4C),
    'hazard critical': Color(0xFFFF5D73),
  };

  /// Every route and trail line, for the checks that must hold across all of
  /// them.
  static const allLines = <String, RouteLineStyle>{
    'route ahead': routeAhead,
    'travelled': travelled,
    'leader trail': leaderTrail,
    'off route': offRouteTrail,
    'rejoin breadcrumb': rejoinBreadcrumb,
  };

  /// Surfaces of the dark basemap as this app renders it: the OpenFreeMap dark
  /// style after `MapStyleRepository` repaints its near-black layers for
  /// legibility. The motorway fill is the lightest of them and therefore the
  /// worst case for a bright line.
  static const darkBasemapSurfaces = <String, Color>{
    'residential': Color(0xFF141414),
    'background': Color(0xFF1C1C1E),
    'water': Color(0xFF15191F),
    'park': Color(0xFF242424),
    'minor road': Color(0xFF3A3A3A),
    'major road': Color(0xFF484848),
    'motorway': Color(0xFF565656),
  };

  /// Surfaces of the light basemap (OpenFreeMap Liberty). Its road fills are
  /// white or near-white, so a bright line cannot contrast with them at all -
  /// the casing is what defines the line here.
  static const lightBasemapSurfaces = <String, Color>{
    'background': Color(0xFFF8F4F0),
    'minor road': Color(0xFFFFFFFF),
    'trunk': Color(0xFFFFEEAA),
    'motorway': Color(0xFFFFCC88),
    'water': Color(0xFF9EBDFF),
    'park': Color(0xFFD8E8C8),
    'building': Color(0xFFDCD9D4),
    'major casing': Color(0xFFE9AC77),
  };
}

/// WCAG 2.1 relative luminance of an opaque colour.
double relativeLuminance(Color color) {
  double channel(double value) => value <= 0.04045
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

/// WCAG 2.1 contrast ratio between two opaque colours, from 1 (identical
/// luminance) to 21 (black against white). Used both to choose the route
/// colours and to assert them in tests.
double contrastRatio(Color first, Color second) {
  final a = relativeLuminance(first);
  final b = relativeLuminance(second);
  return (math.max(a, b) + 0.05) / (math.min(a, b) + 0.05);
}

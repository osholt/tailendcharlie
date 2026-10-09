import 'dart:ui';

/// One stop on a heat ramp: where it sits in the kernel density, the colour the
/// heat takes there and how opaque it is.
class HeatmapRampStop {
  const HeatmapRampStop(this.density, this.color, [this.alpha = 1]);

  /// Position on the ramp, 0 to 1. MapLibre indexes the ramp by the summed
  /// kernel density, which for an isolated cell is its weight times the layer's
  /// intensity.
  final double density;

  /// Opaque colour; translucency is [alpha], never the colour's own channel.
  final Color color;

  /// Opacity of this stop before the layer opacity is applied.
  final double alpha;
}

/// A heat ramp shared by every renderer of one heat layer: the MapLibre
/// `heatmap-color` expression, the Flutter painter and the web planner's copy
/// (`apps/website/global-heatmap.mjs`, held to this one by a test).
class HeatmapRamp {
  const HeatmapRamp({required this.stops, required this.layerOpacity});

  final List<HeatmapRampStop> stops;

  /// `heatmap-opacity` of the layer the ramp colours.
  final double layerOpacity;

  /// The colour at [density], interpolated between stops and held at the ends.
  Color colorAt(double density) {
    final (lower, upper, t) = _span(density);
    return Color.lerp(lower.color, upper.color, t)!;
  }

  /// The opacity at [density] including the layer opacity: what a rider sees
  /// over the basemap.
  double alphaAt(double density) {
    final (lower, upper, t) = _span(density);
    return (lower.alpha + (upper.alpha - lower.alpha) * t) * layerOpacity;
  }

  (HeatmapRampStop, HeatmapRampStop, double) _span(double density) {
    final clamped = density.clamp(stops.first.density, stops.last.density);
    for (var i = 1; i < stops.length; i++) {
      if (clamped <= stops[i].density) {
        final lower = stops[i - 1];
        final upper = stops[i];
        final width = upper.density - lower.density;
        return (
          lower,
          upper,
          width <= 0 ? 1.0 : (clamped - lower.density) / width,
        );
      }
    }
    return (stops.last, stops.last, 1.0);
  }

  /// The MapLibre `heatmap-color` expression. It opens fully transparent in the
  /// first stop's own colour, so interpolating up to the first stop never
  /// passes through grey.
  List<Object> toMapLibreExpression() => [
    'interpolate',
    ['linear'],
    ['heatmap-density'],
    0,
    _css(stops.first.color, 0),
    for (final stop in stops) ...[stop.density, _css(stop.color, stop.alpha)],
  ];

  static String _css(Color color, double alpha) {
    final red = (color.r * 255).round();
    final green = (color.g * 255).round();
    final blue = (color.b * 255).round();
    if (alpha >= 1) {
      final hex = [
        red,
        green,
        blue,
      ].map((c) => c.toRadixString(16).padLeft(2, '0')).join();
      return '#${hex.toUpperCase()}';
    }
    final opacity = alpha == alpha.truncateToDouble()
        ? alpha.toInt().toString()
        : alpha.toString();
    return 'rgba($red,$green,$blue,$opacity)';
  }
}

/// `heatmap-intensity` of the global layer. Weight times this is the density an
/// isolated cell reaches at its centre, which is where the ramp's first stop
/// sits for the lowest weight the relay publishes (0.25).
const double globalHeatmapIntensity = 0.8;

/// The personal layer: violet to orange, on the phone only (unchanged).
const personalHeatmapRamp = HeatmapRamp(
  stops: [
    HeatmapRampStop(0.25, Color(0xFF7C3AED)),
    HeatmapRampStop(0.65, Color(0xFFC2410C)),
    HeatmapRampStop(1, Color(0xFFF97316)),
  ],
  layerOpacity: 0.48,
);

/// The global layer (#913): pink, through a deeper pink, to crimson, becoming
/// more opaque as the road gets busier.
///
/// It replaced a blue to amber to red ramp. Since #905 the layer draws road-level
/// cells and most roads have few rides, so most of the layer sat at the blue
/// end, 13 CIEDE2000 from the good-biking-road blue and 28 from the pass teal;
/// the amber and red above it were 16 and 20 from the twisty orange. Every stop
/// here is at least 30 from all three, and at least 19 from every stop of the
/// personal layer. The numbers, and the contrast against the light and dark
/// basemaps, are in `docs/maps-and-gpx.md`; `heatmap_ramp_test.dart` holds them.
///
/// Opacity rises with density rather than the colour getting paler, because no
/// single colour is lighter than both a light and a dark basemap: the hotter
/// the road, the more it covers.
const globalHeatmapRamp = HeatmapRamp(
  stops: [
    HeatmapRampStop(0.2, Color(0xFFEC4899), 0.5),
    HeatmapRampStop(0.55, Color(0xFFDB2777), 0.6),
    HeatmapRampStop(1, Color(0xFFBE123C), 0.75),
  ],
  layerOpacity: 1,
);

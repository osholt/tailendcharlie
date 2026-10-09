import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/map/heatmap_ramp.dart';
import 'package:ride_relay/features/map/ride_heatmap_layer.dart';
import 'package:ride_relay/features/map/route_trail_style.dart';

/// Cover for #913. Since #905 the global layer draws road-level cells, most of
/// which have few rides and so sat at the cold end of the ramp, which was the
/// same blue as the good-biking-road highlight. These tests hold the ramp to the
/// numbers in `docs/maps-and-gpx.md`; they cannot prove a haze reads as heat in
/// daylight, which needs a photograph from a mounted phone.
void main() {
  // The discovery highlight colours, as `discovery_layer_toggles.dart` draws
  // them. A test below fails if that file stops using these three.
  const discovery = <String, Color>{
    'twisty orange': Color(0xFFF97316),
    'pass teal': Color(0xFF0F9D8A),
    'good-road blue': Color(0xFF2583E9),
  };

  // The old global ramp, kept so the tests prove they would have caught it.
  const oldGlobal = <Color>[
    Color(0xFF0EA5E9),
    Color(0xFFF59E0B),
    Color(0xFFEF4444),
  ];

  // Ground a heat layer sits on. On the phone it is drawn below the road layers
  // (`heatmapRoadLayerId`), so road fills are not behind it there.
  final restrainedLight = <Color>[
    for (final name in ['background', 'water', 'park', 'building'])
      RouteTrailStyle.lightBasemapSurfaces[name]!,
  ];
  const originalLight = <Color>[
    Color(0xFFF8F4F0), // background
    Color(0xFFD8E8C8), // park
    Color(0xFF9EBDFF), // water
  ];
  final dark = <Color>[
    for (final name in ['residential', 'background', 'water', 'park'])
      RouteTrailStyle.darkBasemapSurfaces[name]!,
  ];

  double effectiveContrast(Color heat, double alpha, Color ground) =>
      contrastRatio(
        Color.alphaBlend(heat.withValues(alpha: alpha), ground),
        ground,
      );

  test(
    'the ramp keeps its documented shape: pink to crimson, rising opacity',
    () {
      expect(globalHeatmapRamp.stops.map((s) => s.color), const [
        Color(0xFFEC4899),
        Color(0xFFDB2777),
        Color(0xFFBE123C),
      ]);
      expect(globalHeatmapRamp.stops.map((s) => s.alpha), [0.5, 0.6, 0.75]);
      expect(globalHeatmapRamp.layerOpacity, 1);
      // The lowest weight the relay publishes (0.25) is the cold stop at the
      // centre of an isolated cell, so a sparse road is drawn in the first colour.
      expect(
        0.25 * globalHeatmapIntensity,
        globalHeatmapRamp.stops.first.density,
      );
      for (var i = 1; i < globalHeatmapRamp.stops.length; i++) {
        final previous = globalHeatmapRamp.stops[i - 1];
        final stop = globalHeatmapRamp.stops[i];
        expect(stop.density, greaterThan(previous.density));
        expect(stop.alpha, greaterThanOrEqualTo(previous.alpha));
      }
    },
  );

  test('the MapLibre expression opens transparent in the cold colour', () {
    expect(globalHeatmapRamp.toMapLibreExpression(), [
      'interpolate',
      ['linear'],
      ['heatmap-density'],
      0,
      'rgba(236,72,153,0)',
      0.2,
      'rgba(236,72,153,0.5)',
      0.55,
      'rgba(219,39,119,0.6)',
      1,
      'rgba(190,18,60,0.75)',
    ]);
  });

  test('the personal layer is unchanged by sharing the ramp type', () {
    expect(personalHeatmapRamp.layerOpacity, 0.48);
    expect(personalHeatmapRamp.toMapLibreExpression(), [
      'interpolate',
      ['linear'],
      ['heatmap-density'],
      0,
      'rgba(124,58,237,0)',
      0.25,
      '#7C3AED',
      0.65,
      '#C2410C',
      1,
      '#F97316',
    ]);
  });

  test('no global stop can be mistaken for a discovery highlight', () {
    for (final stop in globalHeatmapRamp.stops) {
      for (final highlight in discovery.entries) {
        expect(
          deltaE2000(stop.color, highlight.value),
          greaterThanOrEqualTo(30),
          reason: '${stop.color} against the ${highlight.key}',
        );
      }
    }
    // And not when it is blended into the basemap, which is what a rider sees.
    for (final ground in [...restrainedLight, ...originalLight, ...dark]) {
      for (final stop in globalHeatmapRamp.stops) {
        final seen = Color.alphaBlend(
          stop.color.withValues(alpha: stop.alpha),
          ground,
        );
        for (final highlight in discovery.entries) {
          expect(
            deltaE2000(seen, highlight.value),
            greaterThanOrEqualTo(20),
            reason: '${stop.color} over $ground against ${highlight.key}',
          );
        }
      }
    }
  });

  test(
    'the old blue-to-red ramp fails the same check, so it is a real one',
    () {
      final worst = oldGlobal
          .expand((heat) => discovery.values.map((d) => deltaE2000(heat, d)))
          .reduce(math.min);
      expect(worst, lessThan(20));
    },
  );

  test(
    'the global ramp is related to the personal one but distinct from it',
    () {
      for (final stop in globalHeatmapRamp.stops) {
        for (final personal in personalHeatmapRamp.stops) {
          expect(
            deltaE2000(stop.color, personal.color),
            greaterThanOrEqualTo(18),
            reason: '${stop.color} against the personal ${personal.color}',
          );
        }
      }
      // Both run cold to hot with a warm, saturated end: the personal layer ends
      // orange, the global one crimson, and neither is blue or green.
      for (final color in [
        ...globalHeatmapRamp.stops.map((s) => s.color),
        ...personalHeatmapRamp.stops.map((s) => s.color),
      ]) {
        final hue = HSLColor.fromColor(color).hue;
        expect(
          hue < 40 || hue > 250,
          isTrue,
          reason: '$color is not a heat hue',
        );
      }
    },
  );

  test('every stop is visible over the light and dark basemaps', () {
    for (final (name, grounds) in [
      ('restrained light', restrainedLight),
      ('original light', originalLight),
      ('dark', dark),
    ]) {
      for (final stop in globalHeatmapRamp.stops) {
        for (final ground in grounds) {
          expect(
            effectiveContrast(
              stop.color,
              stop.alpha * globalHeatmapRamp.layerOpacity,
              ground,
            ),
            greaterThanOrEqualTo(1.4),
            reason: '${stop.color} over $name $ground',
          );
        }
      }
    }
  });

  test('the old ramp measured below that floor on the light basemaps', () {
    final worst = [
      for (final heat in oldGlobal)
        for (final ground in [...restrainedLight, ...originalLight])
          effectiveContrast(heat, 0.42, ground),
    ].reduce(math.min);
    expect(worst, lessThan(1.4));
  });

  test('the ramp interpolates between stops and holds at its ends', () {
    const ramp = globalHeatmapRamp;
    expect(ramp.colorAt(0), ramp.stops.first.color);
    expect(ramp.colorAt(5), ramp.stops.last.color);
    expect(ramp.alphaAt(0.2), closeTo(0.5, 1e-9));
    expect(ramp.alphaAt(1), closeTo(0.75, 1e-9));
    final midway = (0.2 + 0.55) / 2;
    expect(ramp.alphaAt(midway), closeTo(0.55, 1e-9));
    expect(
      ramp.colorAt(midway),
      Color.lerp(ramp.stops[0].color, ramp.stops[1].color, 0.5),
    );
  });

  test('the web planner carries the same ramp', () {
    final source = File('../website/global-heatmap.mjs').readAsStringSync();
    final web = RegExp(
      r'density:\s*([\d.]+),\s*color:\s*"#([0-9a-f]{6})",\s*alpha:\s*([\d.]+)',
    ).allMatches(source).toList();
    expect(web, hasLength(globalHeatmapRamp.stops.length));
    for (var i = 0; i < web.length; i++) {
      final stop = globalHeatmapRamp.stops[i];
      expect(double.parse(web[i].group(1)!), stop.density);
      expect(
        Color(0xFF000000 | int.parse(web[i].group(2)!, radix: 16)),
        stop.color,
      );
      expect(double.parse(web[i].group(3)!), stop.alpha);
    }
    expect(
      source,
      contains('GLOBAL_HEATMAP_INTENSITY = $globalHeatmapIntensity'),
    );
    expect(source, contains('GLOBAL_HEATMAP_LAYER_OPACITY = 1;'));
  });

  test(
    'the discovery colours the ramp is measured against are the real ones',
    () {
      final source = File(
        'lib/features/map/discovery_layer_toggles.dart',
      ).readAsStringSync();
      for (final colour in discovery.values) {
        final hex = colour.toARGB32().toRadixString(16).toUpperCase();
        expect(source, contains('Color(0x$hex)'));
      }
    },
  );

  test('the ride map takes both colour ramps from the shared definitions', () {
    final source = File(
      'lib/features/map/ride_map_feature.dart',
    ).readAsStringSync();
    expect(
      source,
      contains('heatmapColor: globalHeatmapRamp.toMapLibreExpression()'),
    );
    expect(
      source,
      contains('heatmapColor: personalHeatmapRamp.toMapLibreExpression()'),
    );
    expect(source, contains('heatmapIntensity: globalHeatmapIntensity'));
    expect(source, contains('heatmapOpacity: globalHeatmapRamp.layerOpacity'));
    expect(source, isNot(contains("'rgba(14,165,233,0)'")));
    expect(source, isNot(contains("'#0EA5E9'")));
  });

  group('the Flutter painter', () {
    Future<Color> centrePixel({
      required double weight,
      required bool global,
    }) async {
      final recorder = ui.PictureRecorder();
      RideHeatmapPainter(
        points: [(position: const Offset(40, 40), weight: weight)],
        radius: 30,
        global: global,
      ).paint(Canvas(recorder), const Size(80, 80));
      final picture = recorder.endRecording();
      final image = await picture.toImage(80, 80);
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final offset = (40 * 80 + 40) * 4;
      final alpha = data.getUint8(offset + 3);
      image.dispose();
      picture.dispose();
      // Un-premultiply so the pixel can be compared with the stop colour.
      int channel(int i) =>
          (data.getUint8(offset + i) * 255 / math.max(alpha, 1)).round().clamp(
            0,
            255,
          );
      return Color.fromARGB(alpha, channel(0), channel(1), channel(2));
    }

    test('a sparse global road is drawn in the cold stop, not blue', () async {
      final pixel = await centrePixel(weight: 0.25, global: true);
      expect(pixel.a, closeTo(0.5, 0.02));
      expect(
        deltaE2000(
          pixel.withValues(alpha: 1),
          globalHeatmapRamp.stops.first.color,
        ),
        lessThan(3),
      );
      for (final highlight in discovery.values) {
        expect(
          deltaE2000(pixel.withValues(alpha: 1), highlight),
          greaterThan(30),
        );
      }
    });

    test('the busiest global road reaches the hot end of the ramp', () async {
      final pixel = await centrePixel(weight: 1, global: true);
      final expected = globalHeatmapRamp.colorAt(globalHeatmapIntensity);
      expect(deltaE2000(pixel.withValues(alpha: 1), expected), lessThan(3));
      expect(pixel.a, closeTo(globalHeatmapRamp.alphaAt(0.8), 0.02));
    });

    test('the personal layer still draws violet', () async {
      final pixel = await centrePixel(weight: 0, global: false);
      expect(
        deltaE2000(pixel.withValues(alpha: 1), const Color(0xFF7C3AED)),
        lessThan(3),
      );
    });
  });
}

/// CIEDE2000 between two opaque colours (Sharma, Wu and Dalal, 2005): the
/// perceptual distance used in `docs/maps-and-gpx.md`. About 2 is the smallest
/// difference an eye can see side by side; 30 is unmistakably another colour.
double deltaE2000(Color first, Color second) {
  final (l1, a1, b1) = _lab(first);
  final (l2, a2, b2) = _lab(second);
  final c1 = math.sqrt(a1 * a1 + b1 * b1);
  final c2 = math.sqrt(a2 * a2 + b2 * b2);
  final meanC = (c1 + c2) / 2;
  final g =
      0.5 *
      (1 -
          math.sqrt(
            math.pow(meanC, 7) / (math.pow(meanC, 7) + math.pow(25, 7)),
          ));
  final a1p = (1 + g) * a1;
  final a2p = (1 + g) * a2;
  final c1p = math.sqrt(a1p * a1p + b1 * b1);
  final c2p = math.sqrt(a2p * a2p + b2 * b2);
  double hue(double b, double a) {
    if (a == 0 && b == 0) return 0;
    final degrees = math.atan2(b, a) * 180 / math.pi;
    return degrees < 0 ? degrees + 360 : degrees;
  }

  final h1p = hue(b1, a1p);
  final h2p = hue(b2, a2p);
  final dL = l2 - l1;
  final dC = c2p - c1p;
  var dh = 0.0;
  if (c1p * c2p != 0) {
    dh = h2p - h1p;
    if (dh > 180) dh -= 360;
    if (dh < -180) dh += 360;
  }
  final dH = 2 * math.sqrt(c1p * c2p) * math.sin(dh * math.pi / 360);
  final meanL = (l1 + l2) / 2;
  final meanCp = (c1p + c2p) / 2;
  double meanH;
  if (c1p * c2p == 0) {
    meanH = h1p + h2p;
  } else if ((h1p - h2p).abs() <= 180) {
    meanH = (h1p + h2p) / 2;
  } else if (h1p + h2p < 360) {
    meanH = (h1p + h2p + 360) / 2;
  } else {
    meanH = (h1p + h2p - 360) / 2;
  }
  double rad(double degrees) => degrees * math.pi / 180;
  final t =
      1 -
      0.17 * math.cos(rad(meanH - 30)) +
      0.24 * math.cos(rad(2 * meanH)) +
      0.32 * math.cos(rad(3 * meanH + 6)) -
      0.20 * math.cos(rad(4 * meanH - 63));
  final dTheta = 30 * math.exp(-math.pow((meanH - 275) / 25, 2));
  final rc =
      2 *
      math.sqrt(math.pow(meanCp, 7) / (math.pow(meanCp, 7) + math.pow(25, 7)));
  final sl =
      1 +
      0.015 * math.pow(meanL - 50, 2) / math.sqrt(20 + math.pow(meanL - 50, 2));
  final sc = 1 + 0.045 * meanCp;
  final sh = 1 + 0.015 * meanCp * t;
  final rt = -math.sin(rad(2 * dTheta)) * rc;
  return math.sqrt(
    math.pow(dL / sl, 2) +
        math.pow(dC / sc, 2) +
        math.pow(dH / sh, 2) +
        rt * (dC / sc) * (dH / sh),
  );
}

(double, double, double) _lab(Color color) {
  double linear(double c) =>
      c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  final r = linear(color.r);
  final g = linear(color.g);
  final b = linear(color.b);
  final x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
  final y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  final z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;
  double f(double t) =>
      t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
  final fx = f(x);
  final fy = f(y);
  final fz = f(z);
  return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz));
}

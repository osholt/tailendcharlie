import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/map/route_trail_style.dart';
import 'package:ride_relay/services/rider_trail_recorder.dart';

/// Measured cover for #107. These assertions are the numeric part of the fix:
/// they cannot prove sunlight or visor legibility, which needs a photograph from
/// a mounted phone in daylight, but they do hold the palette to the contrast and
/// greyscale-distinguishability rules the issue asks for.
void main() {
  /// The lightest surface of the dark basemap, so the hardest case for a bright
  /// line: an interpolated near-black fill would flatter every colour.
  final darkWorstSurface = RouteTrailStyle.darkBasemapSurfaces['motorway']!;
  final darkTypicalSurface = RouteTrailStyle.darkBasemapSurfaces['background']!;

  test('the reference contrast ratios in the palette docs are accurate', () {
    // The documented table, line by line: dark worst, dark typical, casing.
    const documented = <String, (double, double, double)>{
      'route ahead': (4.11, 9.54, 10.27),
      'travelled': (2.81, 6.52, 7.02),
      'leader trail': (4.22, 9.78, 10.53),
      'off route': (2.73, 6.33, 6.81),
      'rejoin breadcrumb': (4.77, 11.06, 11.91),
    };

    expect(RouteTrailStyle.allLines.keys, documented.keys);
    for (final entry in documented.entries) {
      final line = RouteTrailStyle.allLines[entry.key]!;
      final (worst, typical, casing) = entry.value;
      expect(
        contrastRatio(line.color, darkWorstSurface),
        closeTo(worst, 0.01),
        reason: '${entry.key} dark worst',
      );
      expect(
        contrastRatio(line.color, darkTypicalSurface),
        closeTo(typical, 0.01),
        reason: '${entry.key} dark typical',
      );
      expect(
        contrastRatio(line.color, RouteTrailStyle.casing),
        closeTo(casing, 0.01),
        reason: '${entry.key} against its casing',
      );
    }
  });

  test('the route ahead is far more legible than the blue it replaces', () {
    const previousRouteAhead = Color(0xFF3478F6);

    final previousWorst = contrastRatio(previousRouteAhead, darkWorstSurface);
    final worst = contrastRatio(
      RouteTrailStyle.routeAhead.color,
      darkWorstSurface,
    );

    expect(previousWorst, closeTo(1.80, 0.01));
    expect(worst, greaterThan(previousWorst * 2));
    expect(
      worst,
      greaterThan(4),
      reason: 'the reported failure was the route ahead over a dark basemap',
    );
    for (final surface in RouteTrailStyle.darkBasemapSurfaces.entries) {
      expect(
        contrastRatio(RouteTrailStyle.routeAhead.color, surface.value),
        greaterThan(contrastRatio(previousRouteAhead, surface.value)),
        reason: 'route ahead over the dark basemap\'s ${surface.key}',
      );
    }
  });

  test(
    'every route line clears the field-validated orange on a dark basemap',
    () {
      // The same tester who could not see the blue called the orange trail "quite
      // visible", so it is the floor every other line has to reach.
      final floor = contrastRatio(
        RouteTrailStyle.travelled.color,
        darkWorstSurface,
      );

      for (final entry in RouteTrailStyle.allLines.entries) {
        expect(
          contrastRatio(entry.value.color, darkWorstSurface),
          greaterThanOrEqualTo(floor - 0.1),
          reason: '${entry.key} over the dark basemap motorway fill',
        );
        expect(
          contrastRatio(entry.value.color, darkTypicalSurface),
          greaterThan(4.5),
          reason: '${entry.key} over the dark basemap background',
        );
      }
    },
  );

  test('the casing carries the light basemap, where bright lines cannot', () {
    for (final surface in RouteTrailStyle.lightBasemapSurfaces.entries) {
      expect(
        contrastRatio(RouteTrailStyle.casing, surface.value),
        greaterThan(8),
        reason: 'casing over the light basemap\'s ${surface.key}',
      );
    }
    expect(
      contrastRatio(
        RouteTrailStyle.casing,
        RouteTrailStyle.lightBasemapSurfaces['background']!,
      ),
      closeTo(16.74, 0.01),
    );
    expect(
      contrastRatio(
        RouteTrailStyle.casing,
        RouteTrailStyle.lightBasemapSurfaces['minor road']!,
      ),
      closeTo(18.32, 0.01),
    );
    // Every line also separates from its own casing, which is what defines the
    // line's edge in glare.
    for (final entry in RouteTrailStyle.allLines.entries) {
      expect(
        contrastRatio(entry.value.color, RouteTrailStyle.casing),
        greaterThan(5),
        reason: '${entry.key} against its casing',
      );
    }
    expect(
      RouteTrailStyle.casingHex.toUpperCase(),
      '#${RouteTrailStyle.casing.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
    );
  });

  test('route geometry is opaque; translucency is not used for contrast', () {
    for (final entry in RouteTrailStyle.allLines.entries) {
      expect(entry.value.color.a, 1.0, reason: entry.key);
    }
    expect(RouteTrailStyle.casing.a, 1.0);
    expect(RouteTrailStyle.miniMapRoute.color.a, 1.0);
  });

  test('each line stays identifiable in a greyscale render', () {
    // Five bright colours cannot all separate by luminance - a dark basemap
    // needs every one of them light - so the guarantee is a unique
    // (width, pattern) pair per line, checked here rather than assumed.
    final signatures = <String, String>{
      for (final entry in RouteTrailStyle.allLines.entries)
        entry.key:
            '${entry.value.widthPixels}:${entry.value.dashPixels?.join(',')}',
    };

    expect(signatures.values.toSet(), hasLength(signatures.length));
    expect(
      RouteTrailStyle.allLines.values.map((line) => line.widthPixels).toSet(),
      hasLength(RouteTrailStyle.allLines.length),
      reason: 'width alone also separates them',
    );
    expect(
      RouteTrailStyle.leaderTrail.widthPixels,
      RouteTrailStyle.allLines.values
          .map((line) => line.widthPixels)
          .reduce((a, b) => a > b ? a : b),
      reason: 'the leader trail is the group ground truth',
    );
    expect(RouteTrailStyle.travelled.isDashed, isFalse);
    expect(RouteTrailStyle.leaderTrail.isDashed, isFalse);
    expect(RouteTrailStyle.routeAhead.isDashed, isTrue);
    expect(RouteTrailStyle.offRouteTrail.isDashed, isTrue);
    expect(RouteTrailStyle.rejoinBreadcrumb.isDashed, isTrue);
  });

  test('the route ahead cannot be mistaken for the rejoin breadcrumb', () {
    // Off-route rerouting (#102) owns the cyan rejoin route and renders it
    // dashed. Those are the two lines that both mean "go this way" and that
    // appear together, so they must differ by more than one attribute.
    expect(RouteTrailStyle.rejoinBreadcrumb.color, const Color(0xFF00E5FF));
    expect(
      RouteTrailStyle.routeAhead.color,
      isNot(RouteTrailStyle.rejoinBreadcrumb.color),
    );
    expect(
      RouteTrailStyle.routeAhead.widthPixels,
      greaterThan(RouteTrailStyle.rejoinBreadcrumb.widthPixels),
    );
    expect(
      RouteTrailStyle.routeAhead.dashPixels,
      isNot(RouteTrailStyle.rejoinBreadcrumb.dashPixels),
    );
  });

  test('the route ahead still reads as a line at navigation zoom', () {
    // The dots it replaces were 0.5px long with 9px gaps at width 5.
    final dashes = RouteTrailStyle.routeAhead.dashPixels!;

    expect(dashes.first, greaterThanOrEqualTo(18));
    expect(
      dashes.first / dashes[1],
      greaterThan(1.5),
      reason: 'more line than gap',
    );
    expect(
      RouteTrailStyle.routeAhead.widthPixels,
      greaterThan(RouteTrailStyle.travelled.widthPixels),
    );
  });

  test('a casing dash array keeps the same pixel run as its line', () {
    for (final entry in RouteTrailStyle.allLines.entries) {
      final line = entry.value;
      final dashes = line.dashPixels;
      if (dashes == null) {
        expect(line.maplibreDashArray, isNull, reason: entry.key);
        expect(line.maplibreCasingDashArray, isNull, reason: entry.key);
        continue;
      }
      for (var index = 0; index < dashes.length; index += 1) {
        expect(
          line.maplibreDashArray![index] * line.widthPixels,
          closeTo(dashes[index], 1e-9),
          reason: '${entry.key} line dash $index',
        );
        expect(
          line.maplibreCasingDashArray![index] * line.casingWidthPixels,
          closeTo(dashes[index], 1e-9),
          reason: '${entry.key} casing dash $index',
        );
      }
    }
  });

  test('a casing is always wider than the line it outlines', () {
    for (final entry in {
      ...RouteTrailStyle.allLines,
      'mini-map route': RouteTrailStyle.miniMapRoute,
    }.entries) {
      expect(
        entry.value.fallbackBorderWidthPixels,
        greaterThan(0),
        reason: entry.key,
      );
      expect(
        entry.value.casingWidthPixels,
        greaterThan(entry.value.widthPixels),
        reason: entry.key,
      );
    }
  });

  test('every trail kind has a style', () {
    for (final kind in RiderTrailKind.values) {
      expect(
        RouteTrailStyle.allLines.values,
        contains(RouteTrailStyle.forTrail(kind)),
        reason: kind.name,
      );
    }
    expect(
      RouteTrailStyle.forTrail(RiderTrailKind.rider),
      RouteTrailStyle.travelled,
    );
    expect(
      RouteTrailStyle.forTrail(RiderTrailKind.leader),
      RouteTrailStyle.leaderTrail,
    );
    expect(
      RouteTrailStyle.forTrail(RiderTrailKind.offRoute),
      RouteTrailStyle.offRouteTrail,
    );
  });

  group('marker glyph', () {
    // #133's audit measured every ride-map ink against the dark basemap and found
    // the route palette #107 fixed was fine - every line and pin sits inside an
    // opaque casing worth 4.7-12:1 - while the glyph *inside* a marker badge, the
    // one ink with nothing behind it, ran from 1.53:1 to 3.87:1. That is the
    // symbol that says which rider and how bad a hazard, so it was the least
    // legible thing on the surface.
    test('is dark, and beats white on every badge in the palette', () {
      for (final entry in RouteTrailStyle.markerBadgeFills.entries) {
        final dark = contrastRatio(RouteTrailStyle.markerGlyph, entry.value);
        final white = contrastRatio(const Color(0xFFFFFFFF), entry.value);
        expect(
          dark,
          greaterThan(white),
          reason:
              '${entry.key}: a white glyph would read better, so this badge '
              'needs its own glyph colour rather than the shared dark one',
        );
        // WCAG AA for a graphical object. The worst case is the rider's own blue
        // badge at 4.74:1; the caution yellow is 12.00:1.
        expect(
          dark,
          greaterThanOrEqualTo(3.0),
          reason: '${entry.key}: glyph on badge',
        );
      }
    });

    test('the badge fills themselves stay findable on the dark basemap', () {
      // Each badge carries an opaque casing-coloured stroke, so the number that
      // matters is badge against that stroke rather than against a road fill the
      // badge never touches. This is the rule a new badge has to satisfy - #135's
      // reported camera and police symbols included.
      for (final entry in RouteTrailStyle.markerBadgeFills.entries) {
        expect(
          contrastRatio(entry.value, RouteTrailStyle.casing),
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key}: badge against its own stroke',
        );
      }
    });

    test('the worst and best cases are the documented ones', () {
      final ratios = {
        for (final entry in RouteTrailStyle.markerBadgeFills.entries)
          entry.key: contrastRatio(RouteTrailStyle.markerGlyph, entry.value),
      };
      expect(ratios['own rider'], closeTo(4.74, 0.01));
      expect(ratios['rider yellow'], closeTo(12.00, 0.01));
      expect(ratios['hazard caution'], closeTo(11.91, 0.01));
      // What each of those measured behind a white glyph before the change.
      expect(
        contrastRatio(
          const Color(0xFFFFFFFF),
          RouteTrailStyle.markerBadgeFills['rider yellow']!,
        ),
        closeTo(1.53, 0.01),
      );
    });
  });

  test('relative luminance matches the WCAG reference points', () {
    expect(relativeLuminance(const Color(0xFF000000)), 0);
    expect(relativeLuminance(const Color(0xFFFFFFFF)), closeTo(1, 1e-9));
    expect(
      contrastRatio(const Color(0xFF000000), const Color(0xFFFFFFFF)),
      closeTo(21, 1e-9),
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/features/map/hazard_map_symbol.dart';
import 'package:ride_relay/features/map/route_trail_style.dart';

void main() {
  final reportedAt = DateTime.utc(2026, 7, 27, 12);
  const position = GeoPoint(latitude: 51.5, longitude: -3.18);

  HazardReport report({
    required HazardType type,
    HazardSeverity severity = HazardSeverity.serious,
    Duration life = const Duration(hours: 2),
    int confirmations = 1,
    String? reporterName = 'Alex',
    HazardSource source = HazardSource.rider,
    String? providerId,
  }) => HazardReport(
    id: 'report-1',
    rideId: 'ride-1',
    type: type,
    severity: severity,
    position: position,
    reportedAt: reportedAt,
    updatedAt: reportedAt,
    expiresAt: reportedAt.add(life),
    reporterId: 'rider-1',
    reporterName: reporterName,
    source: source,
    providerId: providerId,
  );

  HazardMapSymbol symbolAt(HazardType type, Duration age) =>
      HazardMapSymbols.forReport(report(type: type), now: reportedAt.add(age));

  group('kind to symbol', () {
    test('a reported camera and a police sighting get their own glyphs', () {
      expect(
        HazardMapSymbols.glyphFor(HazardType.speedCamera),
        HazardMapGlyph.camera,
      );
      expect(
        HazardMapSymbols.glyphFor(HazardType.policeActivity),
        HazardMapGlyph.police,
      );
    });

    test('every other kind the model carries is a road defect', () {
      for (final type in HazardType.values) {
        if (type == HazardType.speedCamera ||
            type == HazardType.policeActivity) {
          continue;
        }
        expect(
          HazardMapSymbols.glyphFor(type),
          HazardMapGlyph.roadDefect,
          reason: type.name,
        );
      }
    });

    test('enforcement is a plate and a road defect is a circle', () {
      // The shape is what separates the two families at a glance, before either
      // glyph is legible.
      final camera = HazardMapSymbols.forReport(
        report(type: HazardType.speedCamera),
        now: reportedAt,
      );
      final police = HazardMapSymbols.forReport(
        report(type: HazardType.policeActivity),
        now: reportedAt,
      );
      final pothole = HazardMapSymbols.forReport(
        report(type: HazardType.pothole),
        now: reportedAt,
      );

      expect(camera.shape, HazardMapBadgeShape.plate);
      expect(police.shape, HazardMapBadgeShape.plate);
      expect(pothole.shape, HazardMapBadgeShape.circle);
      expect(camera.isEnforcement, isTrue);
      expect(pothole.isEnforcement, isFalse);
    });

    test('the two enforcement kinds share one fill and differ by glyph', () {
      final camera = HazardMapSymbols.forReport(
        report(type: HazardType.speedCamera),
        now: reportedAt,
      );
      final police = HazardMapSymbols.forReport(
        report(type: HazardType.policeActivity),
        now: reportedAt,
      );

      expect(camera.fill, HazardMapSymbols.enforcementFill);
      expect(police.fill, HazardMapSymbols.enforcementFill);
      expect(camera.glyph, isNot(police.glyph));
      expect(camera.imageName, isNot(police.imageName));
    });

    test('severity still colours a road defect, unchanged', () {
      // The four fills the map already drew, so a fresh defect looks exactly as
      // it did before this symbol language existed.
      expect(
        HazardMapSymbols.severityFill(HazardSeverity.advisory),
        RouteTrailStyle.markerBadgeFills['hazard advisory'],
      );
      expect(
        HazardMapSymbols.severityFill(HazardSeverity.caution),
        RouteTrailStyle.markerBadgeFills['hazard caution'],
      );
      expect(
        HazardMapSymbols.severityFill(HazardSeverity.serious),
        RouteTrailStyle.markerBadgeFills['hazard serious'],
      );
      expect(
        HazardMapSymbols.severityFill(HazardSeverity.critical),
        RouteTrailStyle.markerBadgeFills['hazard critical'],
      );
    });

    test('enforcement does not reuse a road-defect severity fill', () {
      for (final severity in HazardSeverity.values) {
        expect(
          HazardMapSymbols.enforcementFill,
          isNot(HazardMapSymbols.severityFill(severity)),
        );
      }
    });
  });

  group('freshness', () {
    test('a camera and a police sighting age against their own expiry', () {
      // #112 gives a camera two hours and a police sighting one, because a van
      // moves on. Half an hour in, one is fresh and the other is not.
      final camera = HazardMapSymbols.forReport(
        report(type: HazardType.speedCamera, life: const Duration(hours: 2)),
        now: reportedAt.add(const Duration(minutes: 40)),
      );
      final police = HazardMapSymbols.forReport(
        report(type: HazardType.policeActivity, life: const Duration(hours: 1)),
        now: reportedAt.add(const Duration(minutes: 40)),
      );

      expect(camera.freshness, HazardMapFreshness.fresh);
      expect(police.freshness, HazardMapFreshness.ageing);
    });

    test('it runs fresh, ageing, fading as the report gets older', () {
      expect(
        symbolAt(HazardType.speedCamera, Duration.zero).freshness,
        HazardMapFreshness.fresh,
      );
      expect(
        symbolAt(HazardType.speedCamera, const Duration(minutes: 75)).freshness,
        HazardMapFreshness.ageing,
      );
      expect(
        symbolAt(
          HazardType.speedCamera,
          const Duration(minutes: 110),
        ).freshness,
        HazardMapFreshness.fading,
      );
    });

    test('an ageing symbol differs on three counts, not one', () {
      // A single cue is a single point of failure at ride zoom in sunlight, so
      // the fill, the badge size and the ring pattern all move.
      final fresh = symbolAt(HazardType.speedCamera, Duration.zero);
      final ageing = symbolAt(
        HazardType.speedCamera,
        const Duration(minutes: 75),
      );
      final fading = symbolAt(
        HazardType.speedCamera,
        const Duration(minutes: 110),
      );

      expect(fresh.fill, isNot(ageing.fill));
      expect(ageing.fill, isNot(fading.fill));
      expect(fresh.diameterPixels, greaterThan(ageing.diameterPixels));
      expect(ageing.diameterPixels, greaterThan(fading.diameterPixels));
      expect(fresh.ringDashPixels, isNull);
      expect(ageing.ringDashPixels, isNotNull);
      expect(fading.ringDashPixels, isNotNull);
      expect(ageing.ringDashPixels, isNot(fading.ringDashPixels));
      // And the three are three different images on the native renderer, so the
      // distinction cannot be lost in translation.
      expect({
        fresh.imageName,
        ageing.imageName,
        fading.imageName,
      }, hasLength(3));
    });

    test('the fade washes colour out rather than going transparent', () {
      // Contrast is only measurable for an opaque colour, and #133 measures every
      // ink on this map.
      for (final symbol in HazardMapSymbols.catalogue) {
        expect(symbol.fill.a, 1.0, reason: symbol.imageName);
      }
    });

    test('a re-confirmed sighting reads as fresh again', () {
      // Somebody has just seen it, so freshness runs from the last confirmation
      // rather than from the original report.
      final confirmed =
          report(
            type: HazardType.policeActivity,
            life: const Duration(hours: 1),
          ).copyWith(
            updatedAt: reportedAt.add(const Duration(minutes: 50)),
            expiresAt: reportedAt.add(const Duration(minutes: 110)),
            confirmations: 3,
          );

      expect(
        HazardMapSymbols.freshnessFor(
          confirmed,
          reportedAt.add(const Duration(minutes: 55)),
        ),
        HazardMapFreshness.fresh,
      );
    });

    test('a report at its expiry is fully faded, never mid-life', () {
      expect(
        HazardMapSymbols.lifeFraction(
          report(type: HazardType.speedCamera),
          reportedAt.add(const Duration(hours: 2)),
        ),
        1.0,
      );
      // Past expiry it stays clamped: the relevance judgement drops it, and this
      // must not wrap round to looking fresh if anything ever draws it late.
      expect(
        HazardMapSymbols.lifeFraction(
          report(type: HazardType.speedCamera),
          reportedAt.add(const Duration(hours: 9)),
        ),
        1.0,
      );
      expect(
        symbolAt(HazardType.speedCamera, const Duration(hours: 9)).freshness,
        HazardMapFreshness.fading,
      );
    });

    test('a nonsense expiry window does not divide by zero', () {
      final broken = report(type: HazardType.speedCamera, life: Duration.zero);

      expect(HazardMapSymbols.lifeFraction(broken, reportedAt), 1.0);
    });
  });

  group('legibility, against the table #133 produces', () {
    test('every badge fill beats its own ring by the #133 margin', () {
      // The rule the existing marker-glyph test applies to the hand-written
      // palette, applied here to every fill this resolver can generate - the
      // faded steps of all four road-defect severities included.
      for (final symbol in HazardMapSymbols.catalogue) {
        expect(
          contrastRatio(symbol.fill, RouteTrailStyle.casing),
          greaterThanOrEqualTo(4.5),
          reason: '${symbol.imageName}: badge against its own ring',
        );
      }
    });

    test('the dark glyph still beats a white one on every faded fill', () {
      for (final symbol in HazardMapSymbols.catalogue) {
        final dark = contrastRatio(RouteTrailStyle.markerGlyph, symbol.fill);
        expect(
          dark,
          greaterThan(contrastRatio(const Color(0xFFFFFFFF), symbol.fill)),
          reason: '${symbol.imageName}: a white glyph would read better',
        );
        expect(
          dark,
          greaterThanOrEqualTo(3.0),
          reason: '${symbol.imageName}: glyph on badge',
        );
      }
    });

    test('the enforcement fills are the ones #133 lists', () {
      // Both directions: the shared table must carry these, and they must be the
      // colours the resolver actually draws.
      //
      // Compared as packed 8-bit ARGB rather than with `==`. The table holds
      // literals like `Color(0xFFCCD3DA)`, while the aged fills come out of
      // `Color.lerp`, which interpolates in floating point - the ageing fill
      // lands on red 0.7980 where the literal is 0.8000. That is a difference of
      // half a 1/255 step: the same pixel once rendered, but not the same double.
      // Asserting on `toARGB32()` holds the invariant that actually matters (the
      // table lists the colour a rider sees) at the precision a display can
      // express, which is also the form `hazard_map_symbol.dart` itself hands to
      // MapLibre.
      void expectSameRenderedColour(Color? tabled, Color drawn, String key) =>
          expect(
            tabled?.toARGB32(),
            drawn.toARGB32(),
            reason: '$key: table and resolver disagree on the rendered colour',
          );

      expectSameRenderedColour(
        RouteTrailStyle.markerBadgeFills['enforcement report'],
        HazardMapSymbols.enforcementFill,
        'enforcement report',
      );
      expectSameRenderedColour(
        RouteTrailStyle.markerBadgeFills['enforcement report ageing'],
        symbolAt(HazardType.speedCamera, const Duration(minutes: 75)).fill,
        'enforcement report ageing',
      );
      expectSameRenderedColour(
        RouteTrailStyle.markerBadgeFills['enforcement report fading'],
        symbolAt(HazardType.speedCamera, const Duration(minutes: 110)).fill,
        'enforcement report fading',
      );
    });

    test('the documented enforcement contrast figures are the real ones', () {
      double ratio(String key) => contrastRatio(
        RouteTrailStyle.markerBadgeFills[key]!,
        RouteTrailStyle.casing,
      );

      expect(ratio('enforcement report'), closeTo(17.04, 0.01));
      expect(ratio('enforcement report ageing'), closeTo(12.13, 0.01));
      expect(ratio('enforcement report fading'), closeTo(8.99, 0.01));
    });

    test('an enforcement badge survives both basemaps', () {
      // On the dark basemap the near-white fill carries it; on the light one the
      // road fills are white and the dark ring is what defines the badge, exactly
      // as #107 settled for the route lines.
      for (final surface in RouteTrailStyle.darkBasemapSurfaces.entries) {
        expect(
          contrastRatio(HazardMapSymbols.enforcementFill, surface.value),
          greaterThanOrEqualTo(4.5),
          reason: 'enforcement fill over dark ${surface.key}',
        );
      }
      for (final surface in RouteTrailStyle.lightBasemapSurfaces.entries) {
        expect(
          contrastRatio(RouteTrailStyle.casing, surface.value),
          greaterThanOrEqualTo(4.5),
          reason: 'enforcement ring over light ${surface.key}',
        );
      }
    });

    test('an enforcement badge is the largest marker on the map', () {
      // It must be findable before it is read, and it must not be mistaken for a
      // rider, whose badge is 34 logical pixels.
      final camera = symbolAt(HazardType.speedCamera, Duration.zero);

      expect(camera.diameterPixels, greaterThan(34));
      expect(
        camera.diameterPixels,
        lessThanOrEqualTo(HazardMapSymbols.extentPixels),
      );
    });
  });

  group('the native renderer cannot fall behind the fallback', () {
    test('every symbol a report can produce has a registered image', () {
      // The #141 failure mode, closed: a symbol the resolver can produce but the
      // catalogue does not list would draw perfectly in the flutter_map fallback
      // and every test, and be an invisible marker on the device.
      final registered = HazardMapSymbols.catalogue
          .map((symbol) => symbol.imageName)
          .toSet();

      for (final type in HazardType.values) {
        for (final severity in HazardSeverity.values) {
          for (final minutes in const [0, 75, 110, 400]) {
            final symbol = HazardMapSymbols.forReport(
              report(type: type, severity: severity),
              now: reportedAt.add(Duration(minutes: minutes)),
            );
            expect(
              registered,
              contains(symbol.imageName),
              reason:
                  '${type.name}/${severity.name} at $minutes min has no image',
            );
          }
        }
      }
    });

    test('image names are unique per symbol', () {
      final catalogue = HazardMapSymbols.catalogue;

      expect(
        catalogue.map((symbol) => symbol.imageName).toSet(),
        hasLength(catalogue.length),
      );
    });

    test('the catalogue covers every glyph and every freshness stage', () {
      final catalogue = HazardMapSymbols.catalogue;

      for (final glyph in HazardMapGlyph.values) {
        for (final freshness in HazardMapFreshness.values) {
          expect(
            catalogue.any(
              (symbol) =>
                  symbol.glyph == glyph && symbol.freshness == freshness,
            ),
            isTrue,
            reason: '${glyph.name} ${freshness.name}',
          );
        }
      }
    });
  });

  group('what a tap says', () {
    test('it names the kind, the rider and how long ago', () {
      expect(
        HazardMapSymbols.describe(
          report(type: HazardType.speedCamera),
          now: reportedAt.add(const Duration(minutes: 12)),
        ),
        'Speed camera · Alex 12 min ago',
      );
    });

    test('an ageing report says so in words as well as in ink', () {
      expect(
        HazardMapSymbols.describe(
          report(
            type: HazardType.policeActivity,
            life: const Duration(hours: 1),
          ),
          now: reportedAt.add(const Duration(minutes: 40)),
        ),
        'Police activity · Alex 40 min ago · ageing',
      );
    });

    test('confirmations are counted', () {
      expect(
        HazardMapSymbols.describe(
          report(type: HazardType.speedCamera).copyWith(confirmations: 3),
          now: reportedAt.add(const Duration(minutes: 2)),
        ),
        contains('3 riders'),
      );
    });

    test('a report with no name still says who, honestly', () {
      expect(
        HazardMapSymbols.describe(
          report(type: HazardType.speedCamera, reporterName: null),
          now: reportedAt.add(const Duration(hours: 1)),
        ),
        'Speed camera · a rider 1 h ago · ageing',
      );
    });

    test('a provider incident is not passed off as a rider sighting', () {
      expect(
        HazardMapSymbols.describe(
          report(
            type: HazardType.collision,
            reporterName: null,
            source: HazardSource.externalProvider,
            providerId: 'relay-traffic',
          ),
          now: reportedAt,
        ),
        'Collision · relay-traffic just now',
      );
    });
  });

  group('drawn output', () {
    testWidgets('the badge paints at the size the symbol asks for', (
      tester,
    ) async {
      final symbol = symbolAt(HazardType.speedCamera, Duration.zero);
      await tester.pumpWidget(
        Center(child: HazardMapSymbolBadge(symbol: symbol)),
      );

      final painted = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(HazardMapSymbolBadge),
          matching: find.byType(CustomPaint),
        ),
      );
      expect(painted.size, const Size.square(HazardMapSymbols.extentPixels));
      expect((painted.painter! as HazardMapSymbolPainter).symbol, symbol);
    });

    testWidgets('each kind and each stage draws different pixels', (
      tester,
    ) async {
      // Asserting on the drawn result rather than on the geometry that produced
      // it: #127, #130 and #137 all passed their geometry tests and all shipped a
      // symbol that read wrongly. `render_hazard_symbols.dart` is where these are
      // looked at by eye; this is what stops two of them coming out identical.
      final images = <String, String>{};
      for (final symbol in HazardMapSymbols.catalogue) {
        // `runAsync` is not optional here. `rasterizeHazardMapSymbolPng` ends in
        // `toByteData(format: png)`, which is real engine work rather than
        // something the widget tester's fake-async zone can drive; awaited
        // directly inside `testWidgets` it never completes and the test sits
        // there until the ten-minute timeout kills it. Same reason
        // `quick_message_alert_render_test.dart` wraps its `toImage` call.
        final bytes = await tester.runAsync(
          () => rasterizeHazardMapSymbolPng(symbol),
        );
        expect(bytes, isNotNull, reason: symbol.imageName);
        expect(bytes!, isNotEmpty, reason: symbol.imageName);
        final signature = bytes.fold<int>(
          17,
          (hash, byte) => (hash * 31 + byte) & 0x7FFFFFFF,
        );
        expect(
          images,
          isNot(contains('$signature')),
          reason:
              '${symbol.imageName} rasterises identically to '
              '${images['$signature']}',
        );
        images['$signature'] = symbol.imageName;
      }
      expect(images, hasLength(HazardMapSymbols.catalogue.length));
    });
  });
}

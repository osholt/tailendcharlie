// The group mini-map's camera (#172).
//
// > My mini map is somewhere in North Wales, with none of us in it.
//
// One rider on the Isle of Man, the rest near Bristol, and the mini-map framed
// open sea between them. The framing was `newLatLngBounds` in a 150 x 104 box and
// nothing could test it - the mini-map is MapLibre-only, so no widget test
// touches it. Computing the camera makes it checkable, and these are the checks.
//
// The invariant every case shares: **every framed rider is inside the viewport.**

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart' show GeoPoint;
import 'package:ride_relay/features/map/group_mini_map_framing.dart';

void main() {
  // The portrait mini-map is 150 x 104 with 20/20 and 24/16 padding.
  const width = 110.0;
  const height = 64.0;

  /// Whether [point] lands inside the framed viewport, in projected pixels.
  bool isVisible(
    GroupMiniMapFraming framing,
    GeoPoint point, {
    double tileSize = GroupMiniMapFraming.referenceTileSize,
    double? zoom,
  }) {
    final worldPixels = tileSize * math.pow(2, zoom ?? framing.zoom).toDouble();
    double mercatorY(double latitude) {
      final radians = latitude.clamp(-85.05, 85.05) * math.pi / 180;
      return (1 -
              math.log(math.tan(radians) + 1 / math.cos(radians)) / math.pi) /
          2;
    }

    final dx =
        ((point.longitude - framing.centre.longitude) / 360) * worldPixels;
    final dy =
        (mercatorY(point.latitude) - mercatorY(framing.centre.latitude)) *
        worldPixels;
    return dx.abs() <= width / 2 + 0.5 && dy.abs() <= height / 2 + 0.5;
  }

  group('iOS MapLibre scale', () {
    const west = GeoPoint(latitude: 45.052, longitude: 2.315);
    const east = GeoPoint(latitude: 45.052, longitude: 2.485);

    test('the native camera conversion retains the planned margin', () {
      final framing = GroupMiniMapFraming.forPoints(
        const [west, east],
        width: width,
        height: height,
      );
      final nativeZoom = framing.zoomForTileSize(
        GroupMiniMapFraming.mapLibreNativeTileSize,
      );

      expect(nativeZoom, closeTo(framing.zoom - 1, 1e-9));
      for (final rider in const [west, east]) {
        expect(
          isVisible(
            framing,
            rider,
            tileSize: GroupMiniMapFraming.mapLibreNativeTileSize,
            zoom: nativeZoom,
          ),
          isTrue,
          reason: 'iOS must preserve the same 20 px fit margin',
        );
      }
    });

    test('using the 256 px zoom on iOS reproduces the clipped group', () {
      final framing = GroupMiniMapFraming.forPoints(
        const [west, east],
        width: width,
        height: height,
      );

      expect(
        isVisible(
          framing,
          west,
          tileSize: GroupMiniMapFraming.mapLibreNativeTileSize,
        ),
        isFalse,
      );
      expect(
        isVisible(
          framing,
          east,
          tileSize: GroupMiniMapFraming.mapLibreNativeTileSize,
        ),
        isFalse,
      );
    });
  });

  group('the K-Lo edge case', () {
    // Isle of Man to Bristol: the ride that produced the report.
    const isleOfMan = GeoPoint(latitude: 54.1509, longitude: -4.4816);
    const bristol = GeoPoint(latitude: 51.4545, longitude: -2.5879);
    const swindon = GeoPoint(latitude: 51.5558, longitude: -1.7797);

    test('every rider is inside the viewport, 300 km apart', () {
      const riders = [isleOfMan, bristol, swindon];
      final framing = GroupMiniMapFraming.forPoints(
        riders,
        width: width,
        height: height,
      );

      for (final rider in riders) {
        expect(
          isVisible(framing, rider),
          isTrue,
          reason: 'a mini-map with no rider in view is never correct',
        );
      }
    });

    test('it zooms out far enough rather than giving up', () {
      final framing = GroupMiniMapFraming.forPoints(
        const [isleOfMan, bristol],
        width: width,
        height: height,
      );

      expect(framing.zoom, lessThan(6));
      expect(framing.zoom, greaterThan(GroupMiniMapFraming.minimumZoom));
    });

    test('the span is reported, so a scale can be drawn', () {
      final framing = GroupMiniMapFraming.forPoints(
        const [isleOfMan, bristol],
        width: width,
        height: height,
      );

      // Great-circle Isle of Man to Bristol is about 320 km.
      expect(framing.spanMeters, closeTo(320000, 20000));
      expect(framing.metersPerPixel, greaterThan(0));
    });
  });

  group('spreads a rider should be able to tell apart at a glance', () {
    GroupMiniMapFraming framingSpanning(double kilometres) {
      // Two riders due north-south, so the vertical axis binds.
      const start = GeoPoint(latitude: 51.5, longitude: -2.5);
      final end = GeoPoint(
        latitude: 51.5 + kilometres / 111.32,
        longitude: -2.5,
      );
      return GroupMiniMapFraming.forPoints(
        [start, end],
        width: width,
        height: height,
      );
    }

    test('half a mile, four miles and 195 miles are different views', () {
      final tight = framingSpanning(0.8);
      final middling = framingSpanning(6.4);
      final theKLoCase = framingSpanning(314);

      expect(tight.zoom, greaterThan(middling.zoom));
      expect(middling.zoom, greaterThan(theKLoCase.zoom));
      // And the numbers a scale bar would print differ by orders of magnitude,
      // which is what makes the glance work.
      expect(middling.metersPerPixel / tight.metersPerPixel, greaterThan(4));
      expect(
        theKLoCase.metersPerPixel / middling.metersPerPixel,
        greaterThan(10),
      );
    });

    test('every spread still contains both riders', () {
      for (final kilometres in [0.2, 0.8, 6.4, 40.0, 314.0, 900.0]) {
        const start = GeoPoint(latitude: 51.5, longitude: -2.5);
        final end = GeoPoint(
          latitude: 51.5 + kilometres / 111.32,
          longitude: -2.5,
        );
        final framing = GroupMiniMapFraming.forPoints(
          [start, end],
          width: width,
          height: height,
        );

        expect(
          isVisible(framing, start) && isVisible(framing, end),
          isTrue,
          reason: 'both riders must be framed at a $kilometres km spread',
        );
      }
    });
  });

  group('degenerate inputs', () {
    test('a lone rider gets a street-level view, not a world view', () {
      final framing = GroupMiniMapFraming.forPoints(
        const [GeoPoint(latitude: 51.5, longitude: -2.5)],
        width: width,
        height: height,
      );

      expect(framing.zoom, GroupMiniMapFraming.singleRiderZoom);
      expect(framing.spanMeters, 0);
    });

    test('riders on the same spot do not zoom to infinity', () {
      final framing = GroupMiniMapFraming.forPoints(
        const [
          GeoPoint(latitude: 51.5, longitude: -2.5),
          GeoPoint(latitude: 51.5, longitude: -2.5),
        ],
        width: width,
        height: height,
      );

      expect(framing.zoom, GroupMiniMapFraming.maximumZoom);
      expect(framing.zoom.isFinite, isTrue);
    });

    test('a purely east-west group is framed by its width', () {
      const west = GeoPoint(latitude: 51.5, longitude: -3.5);
      const east = GeoPoint(latitude: 51.5, longitude: -1.5);
      final framing = GroupMiniMapFraming.forPoints(
        const [west, east],
        width: width,
        height: height,
      );

      expect(isVisible(framing, west), isTrue);
      expect(isVisible(framing, east), isTrue);
    });

    test('the zoom never exceeds the group-overview ceiling', () {
      final framing = GroupMiniMapFraming.forPoints(
        const [
          GeoPoint(latitude: 51.50000, longitude: -2.50000),
          GeoPoint(latitude: 51.50001, longitude: -2.50001),
        ],
        width: width,
        height: height,
      );

      expect(framing.zoom, lessThanOrEqualTo(GroupMiniMapFraming.maximumZoom));
    });
  });

  // The 2 August 2026 report: the caption read "2 RIDERS", the mini-map drew no
  // markers at all, and the scale bar said 200 m. The caption counts the roster
  // while the framing only receives riders the map can place, so a rider who has
  // joined without a first position leaves one point here and two in the caption.
  group('a rider who has joined but cannot be placed yet', () {
    const warmley = GeoPoint(latitude: 51.4569, longitude: -2.4735);
    // Where the other rider turned out to be, about 4 km away.
    const oldlandCommon = GeoPoint(latitude: 51.4372, longitude: -2.4560);

    test('one placeable rider alone still gets the street-level view', () {
      final framing = GroupMiniMapFraming.forPoints(
        const [warmley],
        width: width,
        height: height,
      );

      expect(framing.zoom, GroupMiniMapFraming.singleRiderZoom);
    });

    test('one placeable rider in a larger group is framed wider', () {
      final framing = GroupMiniMapFraming.forPoints(
        const [warmley],
        width: width,
        height: height,
        awaitingOtherRiders: true,
      );

      expect(framing.zoom, GroupMiniMapFraming.awaitingOtherRidersZoom);
      expect(
        framing.zoom,
        lessThan(GroupMiniMapFraming.singleRiderZoom),
        reason:
            'a group that cannot all be drawn must not be framed on one '
            'rider at street level',
      );
    });

    test(
      'the wider view already holds a rider who appears kilometres away',
      () {
        // The point of the wider zoom: the first position to arrive should
        // usually already be inside the viewport, so the rider becomes visible
        // even if the refit that would have framed them is late.
        final framing = GroupMiniMapFraming.forPoints(
          const [warmley],
          width: width,
          height: height,
          awaitingOtherRiders: true,
        );

        expect(isVisible(framing, oldlandCommon), isTrue);
      },
    );

    test('the street-level view would have hidden them', () {
      // Establishes that the case above is a real fix and not a tautology.
      final framing = GroupMiniMapFraming.forPoints(
        const [warmley],
        width: width,
        height: height,
      );

      expect(isVisible(framing, oldlandCommon), isFalse);
    });

    test('both riders are framed once the second position arrives', () {
      final framing = GroupMiniMapFraming.forPoints(
        const [warmley, oldlandCommon],
        width: width,
        height: height,
        // Still set, because the roster and the placeable count can disagree
        // for other reasons. With two points it must not change the outcome.
        awaitingOtherRiders: true,
      );

      expect(isVisible(framing, warmley), isTrue);
      expect(isVisible(framing, oldlandCommon), isTrue);
    });
  });
}

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/ride_coordination_mode.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_marker_outline.dart';
import 'package:ride_relay/features/map/motorcycle_icon.dart';

/// #845: the leader and the Tail End Charlie are drawn as stars, so a rider can
/// pick them out of a group at a glance, through a visor, without reading a
/// label. Everyone keeps their own colour; the shape says the role.
void main() {
  group('who is drawn as a star', () {
    test(
      'the leader is a star, whether or not they also hold the TEC role',
      () {
        expect(
          riderMarkerOutlineFor(role: RideRole.lead, isEffectiveTec: false),
          RiderMarkerOutline.star,
        );
        expect(
          riderMarkerOutlineFor(role: RideRole.lead, isEffectiveTec: true),
          RiderMarkerOutline.star,
        );
      },
    );

    test('the Tail End Charlie the ride resolved is a star, whatever their '
        'own role says', () {
      expect(
        riderMarkerOutlineFor(
          role: RideRole.tailEndCharlie,
          isEffectiveTec: true,
        ),
        RiderMarkerOutline.star,
      );
      // A leader's accepted request names the back of the group; the rider it
      // names holds the role in the journal as a plain rider until their own
      // answer lands, and is the back of the group meanwhile.
      expect(
        riderMarkerOutlineFor(role: RideRole.rider, isEffectiveTec: true),
        RiderMarkerOutline.star,
      );
    });

    test('a rider who claims the TEC role but is not the resolved one is a '
        'circle: the group has one back, not two', () {
      expect(
        riderMarkerOutlineFor(
          role: RideRole.tailEndCharlie,
          isEffectiveTec: false,
        ),
        RiderMarkerOutline.circle,
      );
    });

    test('everyone else is a circle', () {
      for (final role in [RideRole.rider, RideRole.marker]) {
        expect(
          riderMarkerOutlineFor(role: role, isEffectiveTec: false),
          RiderMarkerOutline.circle,
          reason: role.name,
        );
      }
    });

    test('a ride of one has no leader to pick out, whatever the creator\'s '
        'role says', () {
      for (final role in RideRole.values) {
        for (final isEffectiveTec in [false, true]) {
          expect(
            riderMarkerOutlineFor(
              role: role,
              isEffectiveTec: isEffectiveTec,
              inGroup: false,
            ),
            RiderMarkerOutline.circle,
            reason: '${role.name}, resolved TEC: $isEffectiveTec',
          );
        }
      }
    });

    group('this phone\'s own marker', () {
      RiderMarkerOutline local({
        RideRole? role = RideRole.lead,
        Set<String> tec = const {},
        RideCoordinationMode mode = RideCoordinationMode.keepTogether,
      }) => localRiderMarkerOutline(
        role: role,
        localRiderId: 'me',
        effectiveTecRiderIds: tec,
        coordinationMode: mode,
      );

      test('is a star for the leader of a group, in either group mode', () {
        for (final mode in [
          RideCoordinationMode.keepTogether,
          RideCoordinationMode.secondBikeDropOff,
        ]) {
          expect(local(mode: mode), RiderMarkerOutline.star, reason: mode.name);
        }
      });

      test('is a circle for a solo rider, although the ride makes them the '
          'lead', () {
        expect(
          local(mode: RideCoordinationMode.solo),
          RiderMarkerOutline.circle,
        );
      });

      test('is a circle with no ride at all', () {
        expect(local(role: null), RiderMarkerOutline.circle);
      });

      test('is a star only while the ride resolves this phone as the back, '
          'not when another rider is', () {
        expect(
          local(role: RideRole.tailEndCharlie, tec: const {'me'}),
          RiderMarkerOutline.star,
        );
        expect(
          local(role: RideRole.tailEndCharlie, tec: const {'someone-else'}),
          RiderMarkerOutline.circle,
          reason: 'a second claimant is not a second star',
        );
        expect(
          local(role: RideRole.rider, tec: const {'me'}),
          RiderMarkerOutline.star,
          reason: 'a leader\'s accepted request names this phone',
        );
      });
    });

    test('every role against every answer to "is the resolved TEC"', () {
      const expected = <(RideRole, bool), RiderMarkerOutline>{
        (RideRole.lead, false): RiderMarkerOutline.star,
        (RideRole.lead, true): RiderMarkerOutline.star,
        (RideRole.rider, false): RiderMarkerOutline.circle,
        (RideRole.rider, true): RiderMarkerOutline.star,
        (RideRole.tailEndCharlie, false): RiderMarkerOutline.circle,
        (RideRole.tailEndCharlie, true): RiderMarkerOutline.star,
        (RideRole.marker, false): RiderMarkerOutline.circle,
        (RideRole.marker, true): RiderMarkerOutline.star,
      };
      // A new role would have to be placed here deliberately.
      expect(expected.length, RideRole.values.length * 2);
      for (final entry in expected.entries) {
        expect(
          riderMarkerOutlineFor(
            role: entry.key.$1,
            isEffectiveTec: entry.key.$2,
          ),
          entry.value,
          reason: '${entry.key.$1.name}, resolved TEC: ${entry.key.$2}',
        );
      }
    });
  });

  group('the star shape', () {
    const size = Size.square(34);
    final centre = size.center(Offset.zero);

    /// How far the shape reaches from its centre in every direction, a degree at
    /// a time, measured by asking the path rather than reading its constants.
    List<double> reach(Path path) => [
      for (var degrees = 0; degrees < 360; degrees += 1)
        () {
          final direction = Offset.fromDirection(
            (degrees - 90) * math.pi / 180,
          );
          var inside = 0.0;
          var outside = size.width;
          for (var step = 0; step < 24; step += 1) {
            final middle = (inside + outside) / 2;
            if (path.contains(centre + direction * middle)) {
              inside = middle;
            } else {
              outside = middle;
            }
          }
          return inside;
        }(),
    ];

    /// The directions (degrees clockwise from up) the shape has a point in:
    /// the local maxima of its reach, ignoring ripples under a pixel.
    List<int> pointsOf(List<double> radii) => [
      for (var degrees = 0; degrees < 360; degrees += 1)
        if (() {
          final here = radii[degrees];
          // The strict maximum of the 30 degrees either side of it.
          for (var offset = -30; offset <= 30; offset += 1) {
            if (offset == 0) continue;
            final other = radii[(degrees + offset + 360) % 360];
            if (other > here || (other == here && offset < 0)) return false;
          }
          return true;
        }())
          degrees,
    ];

    test('a resting star has five points, one of them up', () {
      final radii = reach(
        RiderMarkerShapePainter.shape(
          size,
          directional: false,
          outline: RiderMarkerOutline.star,
        ),
      );
      final points = pointsOf(radii);

      expect(points, hasLength(5));
      expect(points, contains(0));
      for (final point in points) {
        // Rounded a little so a point does not vanish at 34 pixels, so it falls
        // a little short of the constant.
        final nominal = size.width / 2 * RiderMarkerShapePainter.starTipShare;
        expect(
          radii[point],
          inInclusiveRange(nominal * 0.9, nominal),
          reason: 'the point at $point degrees',
        );
      }
    });

    test('a moving star leads with one longer point, which is the front', () {
      final radii = reach(
        RiderMarkerShapePainter.shape(
          size,
          directional: true,
          outline: RiderMarkerOutline.star,
        ),
      );
      final points = pointsOf(radii);

      expect(points, hasLength(5));
      final front = points.reduce(
        (best, point) => radii[point] > radii[best] ? point : best,
      );
      expect(front, 0, reason: 'the longest point is the one facing forward');
      for (final point in points.where((point) => point != front)) {
        expect(
          radii[front],
          greaterThan(radii[point] * 1.1),
          reason:
              'the front leads the point at $point degrees by a margin '
              'that survives at 34 pixels',
        );
      }
    });

    test('has points long enough to read as a star at 34 pixels, not as a '
        'pentagon', () {
      // The first version had points 1.3 times as far from the centre as its
      // valleys, measured, and on the Android emulator it read as a pentagon
      // with notches. The version that reads as a star measures 1.5 to 1.6.
      for (final directional in [false, true]) {
        final radii = reach(
          RiderMarkerShapePainter.shape(
            size,
            directional: directional,
            outline: RiderMarkerOutline.star,
          ),
        );
        final points = pointsOf(radii);
        final valley = radii.reduce(math.min);
        for (final point in points) {
          expect(
            radii[point] / valley,
            greaterThanOrEqualTo(1.45),
            reason:
                'the point at $point degrees (directional: $directional) '
                'against a valley ${valley.toStringAsFixed(1)} pixels deep',
          );
        }
      }
    });

    test('the star reaches at least as far as the circle it replaces', () {
      final circle = reach(
        RiderMarkerShapePainter.shape(size, directional: false),
      ).reduce(math.max);
      for (final directional in [false, true]) {
        final star = reach(
          RiderMarkerShapePainter.shape(
            size,
            directional: directional,
            outline: RiderMarkerOutline.star,
          ),
        ).reduce(math.max);
        expect(
          star,
          greaterThanOrEqualTo(circle),
          reason:
              'a star that is smaller than a circle would be the less '
              'conspicuous marker (directional: $directional)',
        );
      }
    });

    test('the circle is unchanged', () {
      final bounds = RiderMarkerShapePainter.shape(
        size,
        directional: false,
      ).getBounds();
      // 80% of the box, centred: the circle every other marker has always been.
      expect(bounds.left, closeTo(3.4, 1e-4));
      expect(bounds.top, closeTo(3.4, 1e-4));
      expect(bounds.width, closeTo(27.2, 1e-4));
      expect(bounds.height, closeTo(27.2, 1e-4));
    });

    testWidgets('keeps every pixel of the bike inside it, whichever way it is '
        'heading and whichever bike it is', (tester) async {
      await tester.runAsync(() async {
        const badge = 34.0;
        for (final style in MotorcycleIconStyle.values) {
          final image = await decodeImageFromList(
            await loadMotorcycleIconPng(style),
          );
          final alpha = (await image.toByteData())!.buffer.asUint8List();
          // The glyph is drawn upright in a square of `badge * fill`, scaled to
          // fit by its longer side, and only the shape behind it turns.
          final box = badge * riderGlyphBoxFill;
          final scale = math.min(box / image.width, box / image.height);
          final ink = <Offset>[
            for (var y = 0; y < image.height; y += 2)
              for (var x = 0; x < image.width; x += 2)
                if (alpha[(y * image.width + x) * 4 + 3] >= 128)
                  Offset(
                    badge / 2 + (x - image.width / 2) * scale,
                    badge / 2 + (y - image.height / 2) * scale,
                  ),
          ];
          expect(ink, isNotEmpty, reason: style.name);
          for (final directional in [false, true]) {
            for (var heading = 0; heading < 360; heading += 10) {
              final turn = directional ? heading : 0;
              final path =
                  RiderMarkerShapePainter.shape(
                    const Size.square(badge),
                    directional: directional,
                    outline: RiderMarkerOutline.star,
                  ).transform(
                    (Matrix4.identity()
                          ..translateByDouble(badge / 2, badge / 2, 0, 1)
                          ..rotateZ(turn * math.pi / 180)
                          ..translateByDouble(-badge / 2, -badge / 2, 0, 1))
                        .storage,
                  );
              final outside = ink.where((point) => !path.contains(point));
              expect(
                outside,
                isEmpty,
                reason:
                    '${style.name} heading $turn: ${outside.length} of '
                    '${ink.length} pixels of the bike spill out of the star',
              );
            }
          }
        }
      });
    });
  });

  group('the badge', () {
    RiderMarkerShapePainter painter(RiderMarkerOutline outline) =>
        RiderMarkerShapePainter(color: Colors.orange, outline: outline);

    test('repaints when only its shape changes, as a handover changes it', () {
      expect(
        painter(
          RiderMarkerOutline.star,
        ).shouldRepaint(painter(RiderMarkerOutline.circle)),
        isTrue,
      );
      expect(
        painter(
          RiderMarkerOutline.star,
        ).shouldRepaint(painter(RiderMarkerOutline.star)),
        isFalse,
      );
    });

    testWidgets(
      'a map marker takes the shape and the roster\'s badge does not',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Column(
              children: const [
                RiderMarkerBadge(
                  key: Key('on-the-map'),
                  mapMarker: true,
                  style: MotorcycleIconStyle.roadster,
                  badgeColor: Colors.orange,
                  outline: RiderMarkerOutline.star,
                ),
                RiderMarkerBadge(
                  key: Key('in-the-roster'),
                  style: MotorcycleIconStyle.roadster,
                  badgeColor: Colors.orange,
                  outline: RiderMarkerOutline.star,
                ),
              ],
            ),
          ),
        );

        RiderMarkerShapePainter? painted(String key) =>
            tester
                    .widget<CustomPaint>(
                      find.descendant(
                        of: find.byKey(Key(key)),
                        matching: find.byType(CustomPaint),
                      ),
                    )
                    .painter
                as RiderMarkerShapePainter?;
        expect(painted('on-the-map')?.outline, RiderMarkerOutline.star);
        // The list badge is a plain circle whatever it is asked for: the roster
        // names a role in words beside it.
        expect(painted('in-the-roster'), isNull);
      },
    );
  });

  group('the star the native map is given', () {
    Future<(int, List<int>)> decode(
      bool directional,
      RiderMarkerOutline outline,
    ) async {
      final bytes = await rasterizeRiderMarkerShapePng(
        directional: directional,
        outline: outline,
      );
      final image = await decodeImageFromList(bytes);
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
      return (image.width, [for (var i = 3; i < data.length; i += 4) data[i]]);
    }

    testWidgets('is a square with room around the shape for its outline', (
      tester,
    ) async {
      await tester.runAsync(() async {
        for (final directional in [false, true]) {
          final (side, alpha) = await decode(
            directional,
            RiderMarkerOutline.star,
          );
          expect(side, 128 + 2 * 24);
          // The distance field must reach zero before the edge of the image, or
          // the outline is cut off flat.
          for (var index = 0; index < side; index += 1) {
            for (final edge in [
              index,
              (side - 1) * side + index,
              index * side,
              index * side + side - 1,
            ]) {
              expect(
                alpha[edge],
                0,
                reason: 'directional: $directional, pixel $edge',
              );
            }
          }
        }
      });
    });

    testWidgets('a moving one points forward in the image, as the circle\'s '
        'pointer does', (tester) async {
      await tester.runAsync(() async {
        final (side, alpha) = await decode(true, RiderMarkerOutline.star);
        final middle = (side - 1) / 2;
        // Pixels well inside the shape (an SDF encodes 0.75 at the edge).
        double farthest({required bool Function(double degrees) within}) {
          var best = 0.0;
          for (var y = 0; y < side; y += 1) {
            for (var x = 0; x < side; x += 1) {
              if (alpha[y * side + x] < 192) continue;
              final dx = x - middle;
              final dy = y - middle;
              final degrees = (math.atan2(dx, -dy) * 180 / math.pi) % 360;
              if (within(degrees)) {
                best = math.max(best, math.sqrt(dx * dx + dy * dy));
              }
            }
          }
          return best;
        }

        final front = farthest(
          within: (degrees) => degrees < 12 || degrees > 348,
        );
        final others = farthest(
          within: (degrees) => degrees > 40 && degrees < 320,
        );
        expect(front, greaterThan(others * 1.1));
      });
    });

    testWidgets('the circle\'s images keep the size they always had', (
      tester,
    ) async {
      await tester.runAsync(() async {
        for (final directional in [false, true]) {
          final (side, _) = await decode(
            directional,
            RiderMarkerOutline.circle,
          );
          expect(side, 144);
        }
      });
    });

    test('each of the four shapes has its own image name, and the layers '
        'choose between all four', () {
      final names = {
        for (final outline in RiderMarkerOutline.values)
          for (final directional in [false, true])
            riderMarkerShapeImageName(
              outline: outline,
              directional: directional,
            ),
      };
      expect(names, hasLength(4));
      final expression = riderShapeImageExpression.toString();
      for (final name in names) {
        expect(expression, contains(name));
      }
    });
  });
}

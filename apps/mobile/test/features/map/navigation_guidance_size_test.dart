import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/riding_display_size.dart';
import 'package:ride_relay/features/map/maneuver_symbol.dart';
import 'package:ride_relay/features/map/ride_map_feature.dart';
import 'package:ride_relay/services/navigation_guidance.dart';

void main() {
  const maneuver = RouteManeuver(
    position: GeoPoint(latitude: 0, longitude: 0),
    type: 'turn',
    modifier: 'left',
    name: 'A long village street name',
  );
  const instruction = ManeuverInstruction(
    maneuver: maneuver,
    kind: ManeuverKind.turn,
    direction: ManeuverDirection.left,
    text: 'Turn left',
    roadName: 'A long village street name',
  );
  const guidance = NavigationGuidance(
    maneuver: maneuver,
    distanceMeters: 350,
    instruction: instruction,
  );

  for (final viewport in [const Size(320, 568), const Size(568, 320)]) {
    testWidgets(
      'all three guidance sizes fit $viewport with larger system text',
      (tester) async {
        await tester.binding.setSurfaceSize(viewport);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var previousArrow = 0.0;
        var previousText = 0.0;
        for (final size in RidingDisplaySize.values) {
          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(
                  size: viewport,
                  textScaler: TextScaler.linear(1.6),
                ),
                child: Scaffold(
                  body: NavigationGuidanceBanner(
                    guidance: guidance,
                    distanceUnit: DistanceUnit.kilometres,
                    compact: viewport.width > viewport.height,
                    displaySize: size,
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          final arrow = tester.widget<ManeuverSymbolView>(
            find.byType(ManeuverSymbolView),
          );
          final direction = tester.widget<Text>(find.text('Turn left'));
          expect(arrow.size, greaterThan(previousArrow));
          expect(direction.style!.fontSize!, greaterThan(previousText));
          previousArrow = arrow.size;
          previousText = direction.style!.fontSize!;
          expect(find.text('350 m'), findsOneWidget);
          final banner = tester.getRect(
            find.byKey(const Key('navigation-guidance-banner')),
          );
          expect(banner.right, lessThanOrEqualTo(viewport.width));
          expect(banner.bottom, lessThanOrEqualTo(viewport.height));
        }
      },
    );
  }
}

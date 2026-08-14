import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #442's CarPlay layout faults, asserted where they live.
///
/// A head unit is not reachable from a test here, so these read the Swift the
/// same way the #439 reachability check reads Dart: what broke is *placement*,
/// and placement is what the constraints say.
void main() {
  final source = File(
    'ios/Runner/CarPlaySceneDelegate.swift',
  ).readAsStringSync();

  group('the speed pair owns the trailing corner (#442)', () {
    test('the TEC message sits below the speed badge', () {
      // "The no-TEC message goes below the speed limit, not competing with the
      // directions." CarPlay draws the manoeuvre card top-leading, which is
      // where the TEC badge used to be.
      expect(source, contains('tecBadge.topAnchor.constraint('));
      expect(source, contains('equalTo: speedBadge.bottomAnchor'));
    });

    test('the TEC badge no longer claims the leading corner', () {
      expect(
        source.contains(
          'tecBadge.leadingAnchor.constraint(\n'
          '        equalTo: view.safeAreaLayoutGuide.leadingAnchor',
        ),
        isFalse,
        reason: 'that corner belongs to the directions',
      );
    });

    test('a long message cannot reach back across the screen', () {
      expect(
        source,
        contains(
          'greaterThanOrEqualTo: view.safeAreaLayoutGuide.centerXAnchor',
        ),
      );
    });
  });

  group('the mini-map is distinguishable from the map (#442)', () {
    test('it uses the phone landscape footprint', () {
      expect(
        source,
        contains('groupMiniMap.widthAnchor.constraint(equalToConstant: 196)'),
      );
      expect(
        source,
        contains('groupMiniMap.heightAnchor.constraint(equalToConstant: 116)'),
      );
    });

    test('its border is thick enough to read against a basemap', () {
      // "It blends into the main map, so it is not obvious which is which."
      // A 1.5px hairline in the casing grey is invisible over a mostly-grey map.
      expect(source, contains('layer.borderWidth = 3'));
      expect(source, contains('UIColor.white.withAlphaComponent(0.85)'));
    });

    test('it says how far it spans', () {
      // "It needs a clear edge, and a scale, so a rider can tell what they are
      // looking at and how far it spans."
      expect(source, contains('static func spanLabel('));
    });

    test('the scale is in the rider units the rest of the car uses', () {
      expect(source, contains('usesMiles'));
      // Both unit families, and a short form for a group that is close together.
      for (final unit in ['yd', 'mi', 'km']) {
        expect(source, contains(unit), reason: unit);
      }
    });

    test('the caption cannot widen the overview', () {
      // The view is 110pt. #142's rule on the phone is the same one: variable
      // text gives way inside a fixed width rather than moving the surface.
      expect(source, contains('caption.adjustsFontSizeToFitWidth = true'));
      expect(source, contains('caption.trailingAnchor.constraint('));
    });
  });

  group('CarPlay echoes the phone landscape controls (#442)', () {
    test('the ride menu is the same leading compact hamburger', () {
      expect(source, contains('named: "line.3.horizontal"'));
      expect(source, contains('accessibilityLabel: "Ride actions"'));
      expect(source, contains('return CPBarButton(image: image)'));
      expect(source, isNot(contains('CPBarButton(title: "Ride")')));
      expect(
        source,
        contains('mapTemplate.leadingNavigationBarButtons = [rideMenuButton]'),
      );
      expect(
        source,
        isNot(contains('mapTemplate.trailingNavigationBarButtons = [\n')),
      );
      expect(source, contains('? [rideMenuButton, startRideButton()]'));
      expect(source, contains(': [rideMenuButton]'));
    });

    test('follow and SOS use the phone-style glyphs', () {
      expect(source, contains('named: "location.north"'));
      expect(source, contains('named: "sos"'));
      expect(source, isNot(contains('named: "sos.circle.fill"')));
    });

    test('the clock is top-centre and clear of map attribution', () {
      expect(source, contains('clockLabel.centerXAnchor.constraint('));
      expect(source, contains('clockLabel.topAnchor.constraint('));
      expect(source, isNot(contains('clockLabel.bottomAnchor.constraint(')));
    });

    test('route progress shares the bottom status cluster with the mini-map', () {
      expect(source, contains('routeProgressView.leadingAnchor.constraint('));
      expect(source, contains('routeProgressView.bottomAnchor.constraint('));
      expect(
        source,
        contains(
          'routeProgressView.trailingAnchor.constraint(\n'
          '        equalTo: groupMiniMap.leadingAnchor,\n'
          '        constant: -10',
        ),
      );
      expect(
        source,
        contains(
          'routeProgressView.bottomAnchor.constraint(\n'
          '        equalTo: groupMiniMap.bottomAnchor',
        ),
      );
      expect(
        source,
        contains(
          'routeProgressView.leadingAnchor.constraint(\n'
          '        greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor',
        ),
      );
      expect(source, contains('lessThanOrEqualToConstant: 230'));
      expect(source, contains('CarPlayRouteProgressView'));
      expect(source, contains(r'\(duration)'));
      expect(source, contains(r'\(waypointName)'));
    });
  });
}

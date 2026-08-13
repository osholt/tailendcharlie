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
}

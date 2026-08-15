import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #442 and #533's CarPlay layout faults, asserted where they live.
///
/// A head unit is not reachable from a test here, so these read the Swift the
/// same way the #439 reachability check reads Dart: what broke is *placement*,
/// and placement is what the constraints say.
void main() {
  final source = File(
    'ios/Runner/CarPlaySceneDelegate.swift',
  ).readAsStringSync();

  group('the speed pair stays trailing while status moves left (#533)', () {
    test('the TEC message joins the left status column', () {
      expect(
        source,
        contains(
          'tecBadge.leadingAnchor.constraint(\n'
          '        equalTo: groupMiniMap.leadingAnchor',
        ),
      );
      expect(
        source,
        contains(
          'tecBadge.trailingAnchor.constraint(\n'
          '        equalTo: groupMiniMap.trailingAnchor',
        ),
      );
      expect(source, contains('tecBadge.bottomAnchor.constraint('));
      expect(source, contains('equalTo: groupMiniMap.topAnchor'));
      expect(source, isNot(contains('equalTo: speedBadge.bottomAnchor')));
    });

    test('the speed badge keeps its established top-trailing position', () {
      expect(
        source,
        contains('equalTo: view.safeAreaLayoutGuide.trailingAnchor'),
      );
      expect(source, contains('speedBadge.topAnchor.constraint('));
    });
  });

  group('the mini-map is distinguishable from the map (#442)', () {
    test('it scales inside a bounded left rail', () {
      expect(source, contains('equalTo: view.safeAreaLayoutGuide.widthAnchor'));
      expect(source, contains('multiplier: 0.28'));
      expect(source, contains('lessThanOrEqualToConstant: 196'));
      expect(source, contains('multiplier: 116.0 / 196.0'));
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

    test(
      'active ride uses labelled phone-style actions, not template buttons',
      () {
        expect(source, contains('private final class CarPlayRideActionsView'));
        expect(source, contains('title: "ALERT"'));
        expect(source, contains('title: "REPORT"'));
        expect(source, contains('mapTemplate.mapButtons = buttons'));
        expect(source, contains('if surfaceMode != "activeRide"'));
      },
    );

    test('the clock is top-centre and clear of map attribution', () {
      expect(source, contains('clockLabel.centerXAnchor.constraint('));
      expect(source, contains('clockLabel.topAnchor.constraint('));
      expect(source, isNot(contains('clockLabel.bottomAnchor.constraint(')));
    });

    test('route progress stays bottom-trailing beside the left mini-map', () {
      expect(source, contains('routeProgressView.trailingAnchor.constraint('));
      expect(source, contains('routeProgressView.bottomAnchor.constraint('));
      expect(
        source,
        contains(
          'groupMiniMap.leadingAnchor.constraint(\n'
          '        equalTo: view.safeAreaLayoutGuide.leadingAnchor',
        ),
      );
      expect(
        source,
        contains(
          'groupMiniMap.bottomAnchor.constraint(\n'
          '        equalTo: view.bottomAnchor,\n'
          '        constant: -12',
        ),
        reason: 'the full left stack must clear CarPlay’s top navigation bar',
      );
      expect(
        source,
        contains(
          'routeProgressView.trailingAnchor.constraint(\n'
          '        equalTo: view.safeAreaLayoutGuide.trailingAnchor',
        ),
      );
      expect(source, contains('private final class CarPlayGuidanceView'));
      expect(source, contains('equalTo: routeProgressView.topAnchor'));
      expect(source, contains('CarPlayRouteProgressView'));
      expect(source, contains(r'\(duration)'));
      expect(source, contains(r'\(waypointName)'));
    });

    test(
      'MapLibre attribution remains while its fixed compass is replaced',
      () {
        expect(
          source,
          contains('mapView.attributionButtonPosition = .bottomRight'),
        );
        expect(
          source,
          contains('mapView.attributionButtonMargins = CGPoint(x: 52, y: 14)'),
        );
        expect(source, contains('mapView.compassView.isHidden = true'));
        expect(source, contains('private final class CarPlayCompassBadge'));
        expect(
          source,
          contains('compassBadge.widthAnchor.constraint(equalToConstant: 34)'),
        );
      },
    );

    test('primary guidance panes reveal some map context', () {
      expect(source, contains('alpha: 0.85'));
      expect(source, contains('private final class CarPlayGuidanceView'));
      expect(
        source,
        contains('backgroundColor = CarPlayPalette.primaryPanelFill'),
      );
    });

    test('phone anchors are projected onto the CarPlay canvas', () {
      expect(source, contains('riderViewportFraction'));
      expect(source, contains('riderHorizontalViewportFraction'));
      expect(source, contains('let riderChromeClearance: CGFloat = 28'));
      expect(
        source,
        contains('guidanceView.frame.minY - riderChromeClearance'),
      );
      expect(
        source,
        contains('mapView.convert(localCoordinate, toPointTo: mapView)'),
      );
      expect(source, contains('for _ in 0 ..< 3'));
      expect(source, contains('hypot(error.x, error.y) < 1'));
    });

    test('custom action labels cannot wrap on short head units', () {
      expect(
        source,
        contains('configuration.titleLineBreakMode = .byClipping'),
      );
      expect(source, contains('titleLabel?.numberOfLines = 1'));
      expect(source, contains('titleLabel?.adjustsFontSizeToFitWidth = true'));
    });

    test('Apple trip estimate is cancelled in favour of app-owned ETA', () {
      expect(
        source,
        contains(
          'A CPNavigationSession always owns Apple\'s trip-estimate panel',
        ),
      );
      expect(source, contains('navigationSession?.cancelTrip()'));
      expect(source, contains('routeProgressView.trailingAnchor.constraint('));
    });

    test('completed planned route is omitted behind the rider', () {
      expect(source, isNot(contains('travelledRouteAnnotation')));
      expect(source, isNot(contains('snapshot["riddenRoutePoints"]')));
    });
  });

  group('CarPlay home map and ride entry', () {
    test('starts with the phone home fallback instead of the world', () {
      expect(
        source,
        contains('CLLocationCoordinate2D(latitude: 54.5, longitude: -3.2)'),
      );
      expect(source, contains('zoomLevel: 5'));
      expect(source, contains('mapView.setCenter(coordinate, zoomLevel: 14'));
    });

    test('uses matching plan, free-roam, report, and SOS glyphs', () {
      expect(source, contains('named: "magnifyingglass"'));
      expect(source, contains('named: "road.lanes"'));
      expect(source, contains('named: "bell.badge.fill"'));
      expect(source, contains('named: "sos"'));
      expect(source, contains('surfaceMode == "activeRide"'));
    });

    test('search waits for explicit submission', () {
      expect(source, contains('submittedSearchText = searchText'));
      expect(source, contains('completionHandler([])'));
      expect(source, contains('searchTemplateSearchButtonPressed'));
      expect(source, contains('searchCarPlayDestinations(query: query)'));
    });

    test('home hides ride-only status overlays', () {
      expect(source, contains('clockLabel.isHidden = surfaceMode == "home"'));
      expect(source, contains('groupMiniMap.isHidden = true'));
    });
  });
}

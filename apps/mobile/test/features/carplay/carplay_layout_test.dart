import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Structural coverage for the native-only CarPlay surface.
///
/// XCTest proves the live base-view hierarchy contains exactly one MapLibre
/// map. These checks keep controls and driving restrictions on supported
/// CarPlay APIs, where a Flutter widget test cannot instantiate them.
void main() {
  final source = File(
    'ios/Runner/CarPlaySceneDelegate.swift',
  ).readAsStringSync();
  final statusSource = File(
    'ios/Runner/CarPlayStatusTemplate.swift',
  ).readAsStringSync();
  final appDelegateSource = File(
    'ios/Runner/AppDelegate.swift',
  ).readAsStringSync();
  final infoPlistSource = File('ios/Runner/Info.plist').readAsStringSync();
  final viewControllerSource = source.substring(
    source.indexOf('final class CarPlayNavigationViewController'),
    source.indexOf('private final class CarPlayRiderAnnotation'),
  );

  group('the CarPlay base view is one map', () {
    test('only installs the MapLibre map in the root view', () {
      expect(
        viewControllerSource,
        contains('view.insertSubview(mapView, at: 0)'),
      );
      expect(viewControllerSource, isNot(contains('view.addSubview(')));
      for (final legacyOverlay in [
        'CarPlayTecBadge',
        'CarPlaySpeedLimitBadge',
        'CarPlayCompassBadge',
        'CarPlayGroupMiniMapView',
        'CarPlayClockLabel',
        'CarPlayRouteProgressView',
        'CarPlayGuidanceView',
        'CarPlayRideActionsView',
      ]) {
        expect(
          viewControllerSource,
          isNot(contains(legacyOverlay)),
          reason: '$legacyOverlay must not be attached to the base view',
        );
      }
    });

    test('keeps route and rider content inside the map itself', () {
      expect(viewControllerSource, contains('MLNLineStyleLayer('));
      expect(viewControllerSource, contains('CarPlayRiderAnnotationView'));
      expect(viewControllerSource, isNot(contains('riddenRoutePoints')));
    });
  });

  group('all driving controls use CarPlay APIs', () {
    test('active ride retains pan, follow, report, SOS, leave, and status', () {
      expect(source, contains('compassPanButton(mapTemplate: mapTemplate)'));
      expect(source, contains('recenterButton()'));
      expect(source, contains('reportBarButton()'));
      expect(source, contains('emergencyBarButton()'));
      expect(source, contains('zoomButton(delta: 1)'));
      expect(source, contains('zoomButton(delta: -1)'));
      expect(source, contains('presentLeaveConfirmation()'));
      expect(source, contains('leaveRideFromCarPlay(completion: completion)'));
      expect(source, contains('return CPBarButton(image: image)'));
      expect(statusSource, contains('text: "Leave ride"'));
      expect(statusSource, contains('leave.handler ='));
      expect(statusSource, contains('CPBarButton(title: "SOS")'));
      expect(source, contains('tecStatusButton(snapshot)'));
      expect(source, contains('groupOverviewButton(snapshot)'));
      expect(source, contains('func showGroupOverview()'));
      expect(source, contains('CarPlayTecBarPresentation.title'));
      expect(source, contains('CarPlayAutomaticGroupOverviewPolicy'));
      expect(source, contains('updateAutomaticGroupOverview('));
      const activeRideBarPolicy =
          'mapTemplate.automaticallyHidesNavigationBar = '
          'surfaceMode != "activeRide"';
      expect(source, contains(activeRideBarPolicy));
      final surfaceActions = source.indexOf(
        'private func updateSurfaceActions',
      );
      final barPolicy = source.indexOf(activeRideBarPolicy);
      final mapButtons = source.indexOf(
        'mapTemplate.mapButtons = [',
        surfaceActions,
      );
      expect(barPolicy, greaterThan(surfaceActions));
      expect(barPolicy, lessThan(mapButtons));
      expect(source, contains('case .showGroupOverview:'));
      expect(source, contains('case .returnToFollow:'));
      expect(viewControllerSource, contains('groupOverviewRequested'));
      expect(
        viewControllerSource,
        contains(
          'if groupOverviewRequested, requestedRiderFollow {\n'
          '      maintainGroupOverview()\n'
          '      return\n'
          '    }',
        ),
      );
      expect(viewControllerSource, contains('riderEscapedMargin'));
      expect(statusSource, contains('text: "Show all riders on map"'));
      expect(statusSource, contains('text: "Speed"'));
      expect(statusSource, contains('text: "Journey"'));
      expect(statusSource, contains('text: "Then · \\(instruction)"'));
    });

    test('home retains route planning and recorded free roam', () {
      expect(source, contains('named: "magnifyingglass"'));
      expect(source, contains('named: "road.lanes"'));
      expect(source, contains('presentDestinationSearch()'));
      expect(source, contains('presentFreeRoamConfirmation()'));
    });

    test('Apple navigation owns manoeuvres, estimates, and alerts', () {
      expect(source, contains('mapTemplate.startNavigationSession(for: trip)'));
      expect(
        source,
        contains('navigationSession.upcomingManeuvers = maneuvers'),
      );
      expect(source, contains('session.updateEstimates('));
      expect(source, contains('mapTemplate.updateEstimates('));
      expect(source, contains('CPNavigationAlert('));
      expect(
        source,
        contains(') -> CPManeuverDisplayStyle {\n    .leadingSymbol'),
      );
      expect(source, contains('maneuver.attributedInstructionVariants ='));
      expect(
        source,
        contains('interfaceController?.topTemplate !== statusTemplate'),
      );
      expect(
        source,
        contains('CarPlayGroupOverviewGeometry.uniqueCoordinates'),
      );
    });
  });

  group('panning and driving restrictions', () {
    test('touch and non-touch hosts can enter, pan, and exit', () {
      expect(
        source,
        contains('mapTemplate.showPanningInterface(animated: true)'),
      );
      expect(source, contains('mapTemplateDidShowPanningInterface'));
      expect(source, contains('mapTemplateDidDismissPanningInterface'));
      expect(source, contains('panBeganWith direction'));
      expect(source, contains('panEndedWith direction'));
      expect(source, contains('beginDirectionalPan(direction: direction)'));
      expect(source, contains('endDirectionalPan()'));
    });

    test('applicable host gestures reach the map', () {
      expect(source, contains('mapTemplateDidBeginZoomGesture'));
      expect(source, contains('didUpdateZoomGestureWithCenter'));
      expect(source, contains('mapTemplateDidBeginRotationGesture'));
      expect(source, contains('didRotateWithCenter'));
      expect(source, contains('mapTemplateDidBeginPitchGesture'));
      expect(source, contains('pitchWithCenter'));
    });

    test('keyboard and list restrictions change exposed content', () {
      expect(source, contains('CPSessionConfiguration(delegate: self)'));
      expect(source, contains('limitedUserInterfacesChanged'));
      expect(source, contains('interactionPolicy.allowsDestinationSearch'));
      expect(statusSource, contains('if !listsLimited'));
    });
  });

  group('map behavior remains usable', () {
    test('vertical framing and the fixed open right third are projected', () {
      expect(source, contains('riderViewportFraction'));
      expect(source, contains('let riderHorizontalFraction = 2.0 / 3.0'));
      expect(source, isNot(contains('leftHandTraffic ? (2.0 / 3.0)')));
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

    test('host safe areas drive every camera mode and route overview', () {
      expect(source, contains('CarPlayMapSafeArea('));
      expect(viewControllerSource, contains('viewSafeAreaInsetsDidChange()'));
      expect(
        viewControllerSource,
        contains('mapView.contentInset = safeArea.contentInsets'),
      );
      expect(viewControllerSource, contains('safeFrame.height'));
      expect(viewControllerSource, contains('overviewCoordinates('));
      expect(
        viewControllerSource,
        contains('riderAnnotations.map(\\.coordinate)'),
      );
      expect(viewControllerSource, contains('maneuverCoordinates'));
    });

    test('CarPlay host appearance owns the day and night basemap', () {
      expect(source, contains('contentStyleChanged contentStyle'));
      expect(source, contains('contentStyleDidChange('));
      expect(source, contains('applyHostContentStyle('));
      expect(
        viewControllerSource,
        contains('hostContentStyle.contains(.dark)'),
      );
      expect(
        viewControllerSource,
        isNot(contains('traitCollection.userInterfaceStyle == .dark')),
      );
    });

    test('search waits for explicit submission', () {
      expect(source, contains('submittedSearchText = searchText'));
      expect(source, contains('completionHandler([])'));
      expect(source, contains('searchTemplateSearchButtonPressed'));
      expect(source, contains('searchCarPlayDestinations(query: query)'));
    });
  });

  group('projected flows remain self-contained', () {
    test('pre-drive requirements never direct a rider back to the phone', () {
      final projectedStrings = '$source\n$statusSource';
      expect(projectedStrings, isNot(contains('Finish setup on iPhone')));
      expect(projectedStrings, isNot(contains('Try again on the iPhone')));
      expect(projectedStrings, isNot(contains('unlock the iPhone')));
      expect(
        statusSource,
        contains('text: enabled ? "Ready to start" : "Ride not ready"'),
      );
    });

    test(
      'commands complete or time out and unlock refreshes retained state',
      () {
        expect(appDelegateSource, contains('CarPlayCommandCompletion'));
        expect(appDelegateSource, contains('deadline: .now() + 8'));
        expect(
          appDelegateSource,
          contains('applicationProtectedDataDidBecomeAvailable'),
        );
        expect(appDelegateSource, contains('invokeMethod("requestState"'));
        expect(source, contains('performConfirmedAction('));
      },
    );
  });

  group('Dashboard lifecycle', () {
    test('declares and installs the navigation Dashboard scene', () {
      expect(infoPlistSource, contains('CPSupportsDashboardNavigationScene'));
      expect(
        infoPlistSource,
        contains('CPTemplateApplicationDashboardSceneSessionRoleApplication'),
      );
      expect(infoPlistSource, contains('CarPlayDashboardSceneDelegate'));
      expect(source, contains('CPTemplateApplicationDashboardSceneDelegate'));
      expect(source, contains('window.rootViewController = mapViewController'));
      expect(source, contains('dashboardController.shortcutButtons = []'));
    });

    test('main and Dashboard windows are retained and cleared by identity', () {
      expect(source, contains('private var carWindow: CPWindow?'));
      expect(source, contains('carWindow === window'));
      expect(source, contains('carWindow = nil'));
      expect(source, contains('private var dashboardWindow: UIWindow?'));
      expect(source, contains('dashboardWindow === window'));
      expect(source, contains('dashboardWindow = nil'));
    });

    test(
      'cached projection reaches both scenes without a second ride owner',
      () {
        expect(appDelegateSource, contains('carPlayDashboardDidConnect('));
        expect(
          appDelegateSource,
          contains('carPlayDashboardSceneDelegate?.apply(snapshot: value)'),
        );
        expect(source, contains('CarPlayDashboardProjectionState'));
        expect(
          source,
          isNot(contains('dashboardController.startNavigationSession')),
        );
      },
    );
  });
}

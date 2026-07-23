import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/navigation_export.dart';

void main() {
  test(
    'capability registry is complete and makes transfer limits explicit',
    () {
      expect(
        navigationHandoffCapabilities.map((capability) => capability.target),
        unorderedEquals(NavigationTarget.values),
      );
      for (final platform in NavigationPlatform.values) {
        expect(
          navigationCapabilitiesFor(
            platform,
          ).map((capability) => capability.target),
          unorderedEquals(NavigationTarget.values),
          reason: 'Every current handoff should declare $platform support',
        );
      }

      expect(
        NavigationTarget.googleMaps.capability.routeTransfer,
        NavigationRouteTransfer.sampledWaypoints,
      );
      expect(
        NavigationTarget.waze.capability.routeTransfer,
        NavigationRouteTransfer.destinationOnly,
      );
      for (final target in [
        NavigationTarget.shareGpx,
        NavigationTarget.calimoto,
        NavigationTarget.myRouteApp,
        NavigationTarget.garmin,
        NavigationTarget.bmwMotorrad,
        NavigationTarget.harleyDavidson,
      ]) {
        expect(
          target.capability.routeTransfer,
          NavigationRouteTransfer.fullGpx,
        );
        expect(target.hasDocumentedDirectLink, isFalse);
      }
    },
  );

  test(
    'a platform-exclusive capability is excluded from the other platform',
    () {
      // Every current entry declares both platforms, so this is the only
      // path that exercises exclusion - a synthetic capability here, not a
      // fabricated real provider, since none of the seven actual entries are
      // genuinely platform-exclusive.
      const androidOnly = NavigationHandoffCapability(
        target: NavigationTarget.garmin,
        label: 'Garmin (Android only, hypothetical)',
        transport: NavigationHandoffTransport.gpxShare,
        routeTransfer: NavigationRouteTransfer.fullGpx,
        platforms: {NavigationPlatform.android},
        limitation: 'test fixture',
      );

      expect(androidOnly.supports(NavigationPlatform.android), isTrue);
      expect(androidOnly.supports(NavigationPlatform.iOS), isFalse);
    },
  );

  test('Google Maps link is bounded to three sampled via points', () {
    final uri = RouteNavigationLinks.googleMaps(_route(10))!;

    expect(uri.scheme, 'https');
    expect(uri.host, 'www.google.com');
    expect(uri.queryParameters['api'], '1');
    expect(uri.queryParameters['travelmode'], 'driving');
    expect(uri.queryParameters['waypoints']!.split('|'), hasLength(3));
    expect(uri.toString().length, lessThan(2048));
  });

  test('Waze link honestly transfers only the final destination', () {
    final uri = RouteNavigationLinks.waze(_route(4))!;

    expect(uri.host, 'waze.com');
    expect(uri.queryParameters['ll'], '53.030000,-1.030000');
    expect(uri.queryParameters['navigate'], 'yes');
    expect(uri.queryParameters['vehicle_type'], 'motorcycle');
    expect(uri.queryParameters, isNot(contains('waypoints')));
  });

  test('failed direct handoff falls back to GPX sharing', () async {
    final launcher = _FakeLauncher(result: false);
    final gateway = _FakeShareGateway();
    final coordinator = NavigationExportCoordinator(
      launcher: launcher,
      shareGateway: gateway,
    );

    final result = await coordinator.export(
      NavigationTarget.googleMaps,
      _route(4),
    );

    expect(launcher.opened, hasLength(1));
    expect(gateway.targets, [NavigationTarget.googleMaps]);
    expect(result.openedDirectly, isFalse);
    expect(result.sharedGpx, isTrue);
  });

  test('a direct handoff that throws (rather than returning false) also falls '
      'back to GPX sharing', () async {
    final launcher = _FakeLauncher(result: true, throws: true);
    final gateway = _FakeShareGateway();
    final coordinator = NavigationExportCoordinator(
      launcher: launcher,
      shareGateway: gateway,
    );

    final result = await coordinator.export(NavigationTarget.waze, _route(4));

    expect(launcher.opened, hasLength(1));
    expect(gateway.targets, [NavigationTarget.waze]);
    expect(result.openedDirectly, isFalse);
    expect(result.sharedGpx, isTrue);
  });

  test('a route with no navigable points falls back to GPX sharing without '
      'attempting to launch a direct link', () async {
    final launcher = _FakeLauncher(result: true);
    final gateway = _FakeShareGateway();
    final coordinator = NavigationExportCoordinator(
      launcher: launcher,
      shareGateway: gateway,
    );

    final result = await coordinator.export(
      NavigationTarget.googleMaps,
      _route(0),
    );

    expect(launcher.opened, isEmpty);
    expect(gateway.targets, [NavigationTarget.googleMaps]);
    expect(result.sharedGpx, isTrue);
  });

  test('GPX-only targets never use invented URL schemes', () async {
    final launcher = _FakeLauncher(result: true);
    final gateway = _FakeShareGateway();
    final coordinator = NavigationExportCoordinator(
      launcher: launcher,
      shareGateway: gateway,
    );

    for (final target in [
      NavigationTarget.calimoto,
      NavigationTarget.myRouteApp,
      NavigationTarget.garmin,
      NavigationTarget.bmwMotorrad,
      NavigationTarget.harleyDavidson,
    ]) {
      await coordinator.export(target, _route(4));
    }

    expect(launcher.opened, isEmpty);
    expect(gateway.targets, [
      NavigationTarget.calimoto,
      NavigationTarget.myRouteApp,
      NavigationTarget.garmin,
      NavigationTarget.bmwMotorrad,
      NavigationTarget.harleyDavidson,
    ]);
  });
}

ImportedRoute _route(int count) => ImportedRoute(
  id: 'route',
  name: 'Test route',
  importedAt: DateTime.utc(2026),
  sourceFileName: 'test.gpx',
  paths: [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        for (var index = 0; index < count; index += 1)
          GeoPoint(latitude: 53 + index / 100, longitude: -1 - index / 100),
      ],
    ),
  ],
  waypoints: const [],
);

class _FakeLauncher implements ExternalUriLauncher {
  _FakeLauncher({required this.result, this.throws = false});

  final bool result;
  final bool throws;
  final List<Uri> opened = [];

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    if (throws) throw StateError('launch failed');
    return result;
  }
}

class _FakeShareGateway implements GpxShareGateway {
  final List<NavigationTarget> targets = [];

  @override
  Future<void> share({
    required ImportedRoute route,
    required NavigationTarget target,
    Rect? sharePositionOrigin,
  }) async {
    targets.add(target);
  }
}

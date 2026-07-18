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
      ]) {
        expect(
          target.capability.routeTransfer,
          NavigationRouteTransfer.fullGpx,
        );
        expect(target.hasDocumentedDirectLink, isFalse);
      }
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
    ]) {
      await coordinator.export(target, _route(4));
    }

    expect(launcher.opened, isEmpty);
    expect(gateway.targets, [
      NavigationTarget.calimoto,
      NavigationTarget.myRouteApp,
      NavigationTarget.garmin,
      NavigationTarget.bmwMotorrad,
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
  _FakeLauncher({required this.result});

  final bool result;
  final List<Uri> opened = [];

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
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

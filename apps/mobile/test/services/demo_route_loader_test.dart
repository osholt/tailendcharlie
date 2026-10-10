import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart' as geo;
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/demo_route_loader.dart';
import 'package:ride_relay/services/geo_calculations.dart';

double _lengthMeters(ImportedRoute route) {
  final points = route.paths.single.points;
  var total = 0.0;
  for (var index = 1; index < points.length; index += 1) {
    total += GeoCalculations.distanceMeters(
      geo.GeoPoint(
        latitude: points[index - 1].latitude,
        longitude: points[index - 1].longitude,
      ),
      geo.GeoPoint(
        latitude: points[index].latitude,
        longitude: points[index].longitude,
      ),
    );
  }
  return total;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled French demo follows the supplied Day 3 route', () async {
    final route = await const BundledDemoRouteLoader(DemoRoutes.france).load();

    expect(route.name, 'Argentat to Saint-Privat — France');
    expect(route.pathPointCount, greaterThan(450));
    expect(route.waypoints, hasLength(3));
    expect(route.waypoints.first.name, 'Pont Henri IV, Argentat');
    expect(route.waypoints.last.name, 'Saint-Privat');
    expect(route.maneuvers, hasLength(4));

    final points = route.paths.single.points;
    expect(points.first.latitude, closeTo(45.09125, 0.00001));
    expect(points.first.longitude, closeTo(1.94011, 0.00001));
    expect(points.last.latitude, closeTo(45.13701, 0.00001));
    expect(points.last.longitude, closeTo(2.10279, 0.00001));
  });

  test(
    'bundled French demo includes map-derived second-bike-drop decisions',
    () async {
      final maneuvers = await const BundledDemoRouteLoader(
        DemoRoutes.france,
      ).loadManeuvers();

      expect(maneuvers, hasLength(4));
      expect(maneuvers.first.type, 'turn');
      expect(
        maneuvers.map((maneuver) => maneuver.name),
        contains('Rue de Bellevue'),
      );
      expect(
        maneuvers.map((maneuver) => maneuver.type),
        contains('roundabout'),
      );
      expect(
        maneuvers.every((maneuver) => maneuver.drivingSide == 'right'),
        isTrue,
      );
      expect(
        maneuvers.every((maneuver) => maneuver.trafficSideConfirmed),
        isTrue,
      );
    },
  );

  test(
    'the Cotswolds demo is a UK road route driven on the left (#934)',
    () async {
      final loader = const BundledDemoRouteLoader(DemoRoutes.cotswolds);
      final route = await loader.load();

      expect(route.name, 'Castle Combe to Tetbury — Cotswolds');
      expect(route.sourceFileName, 'demo_route_cotswolds.gpx');
      expect(route.pathPointCount, greaterThan(400));
      // Within the UK, and well away from anywhere in France.
      for (final point in route.paths.single.points) {
        expect(point.latitude, inInclusiveRange(51.4, 51.7));
        expect(point.longitude, inInclusiveRange(-2.4, -2.0));
      }
      // About the 24.5 km it is described as, not a stub.
      expect(_lengthMeters(route) / 1000, inInclusiveRange(23.0, 26.0));

      final maneuvers = await loader.loadManeuvers();
      expect(maneuvers.length, greaterThanOrEqualTo(6));
      expect(
        maneuvers.every((maneuver) => maneuver.requiresSecondBikeDrop),
        isTrue,
        reason: 'a bike-drop demo needs decisions a bike can be dropped at',
      );
      // The public OSRM server reports right-hand traffic for UK roads, so the
      // side is stated by hand in the bundled file. Nothing may fall back to it.
      expect(
        maneuvers.every((maneuver) => maneuver.drivingSide == 'left'),
        isTrue,
      );
      expect(
        maneuvers.every((maneuver) => maneuver.trafficSideConfirmed),
        isTrue,
      );
    },
  );

  test('every bundled demo has a distinct id and file, and is found by '
      'the file name its loaded route carries', () {
    final ids = DemoRoutes.all.map((route) => route.id).toSet();
    final files = DemoRoutes.all.map((route) => route.sourceFileName).toSet();
    expect(ids, hasLength(DemoRoutes.all.length));
    expect(files, hasLength(DemoRoutes.all.length));
    for (final route in DemoRoutes.all) {
      expect(DemoRoutes.forSourceFileName(route.sourceFileName), same(route));
    }
    expect(DemoRoutes.forSourceFileName('my-ride.gpx'), isNull);
    expect(DemoRoutes.forSourceFileName(null), isNull);
  });

  test('an unknown or missing remembered id falls back to the default', () {
    expect(DemoRoutes.byId(DemoRoutes.france.id), same(DemoRoutes.france));
    expect(DemoRoutes.byId('no-such-route'), same(DemoRoutes.fallback));
    expect(DemoRoutes.byId(null), same(DemoRoutes.fallback));
  });
}

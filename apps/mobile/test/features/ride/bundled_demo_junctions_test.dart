import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart' as geo;
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/ride/active_ride_shell.dart';
import 'package:ride_relay/services/demo_route_loader.dart';
import 'package:ride_relay/services/geo_calculations.dart';

/// **Each demo marks its own junctions (#934).**
///
/// Ride Lab drops the second bike at the decisions in a route's bundled
/// manoeuvre file. With two routes, picking the wrong file would not crash: it
/// would quietly mark junctions in another country.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final demo in DemoRoutes.all) {
    test(
      '${demo.title}: every marked junction lies on its own route',
      () async {
        final route = await BundledDemoRouteLoader(demo).load();
        final junctions = await bundledDemoJunctions(route);

        expect(junctions, isNotNull);
        expect(junctions, isNotEmpty);
        final path = [
          for (final point in route.paths.single.points)
            geo.GeoPoint(latitude: point.latitude, longitude: point.longitude),
        ];
        for (final junction in junctions!) {
          final nearest = path
              .map(
                (point) => GeoCalculations.distanceMeters(
                  point,
                  geo.GeoPoint(
                    latitude: junction.latitude,
                    longitude: junction.longitude,
                  ),
                ),
              )
              .reduce((a, b) => a < b ? a : b);
          expect(
            nearest,
            lessThan(40),
            reason:
                'a junction ${nearest.round()} m from the nearest point of '
                '${demo.title} was read from some other route',
          );
        }
      },
    );
  }

  test('a route that is not a bundled demo has none to offer', () async {
    final route = await const BundledDemoRouteLoader(DemoRoutes.france).load();
    final renamed = ImportedRoute(
      id: route.id,
      name: route.name,
      importedAt: route.importedAt,
      sourceFileName: 'my-ride.gpx',
      paths: route.paths,
      waypoints: route.waypoints,
    );
    expect(await bundledDemoJunctions(renamed), isNull);
    expect(await bundledDemoJunctions(null), isNull);
  });
}

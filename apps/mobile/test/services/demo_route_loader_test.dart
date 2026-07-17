import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/demo_route_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled demo follows roads from Kings Oak to Cross Hands', () async {
    final route = await const BundledDemoRouteLoader().load();

    expect(route.name, "King's Oak Academy to Cross Hands Hotel");
    expect(route.pathPointCount, greaterThan(450));
    expect(route.waypoints, hasLength(3));
    expect(route.waypoints.first.name, "King's Oak Academy car park");
    expect(route.waypoints.last.name, 'Cross Hands Hotel car park');

    final points = route.paths.single.points;
    expect(points.first.latitude, closeTo(51.462674, 0.00001));
    expect(points.first.longitude, closeTo(-2.484519, 0.00001));
    expect(points.last.latitude, closeTo(51.528729, 0.00001));
    expect(points.last.longitude, closeTo(-2.342245, 0.00001));
  });
}

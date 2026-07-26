import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/map/maneuver_list_screen.dart';
import 'package:ride_relay/services/navigation_guidance.dart';

import '../../services/osrm_maneuver_fixtures.dart';

void main() {
  const planner = NavigationGuidancePlanner();

  testWidgets('lists every manoeuvre in riding order with distances', (
    tester,
  ) async {
    final route = await routeFromOsrmResponse(multiRoundaboutUrbanResponse());

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: ManeuverListScreen(
          route: route,
          distanceUnit: DistanceUnit.kilometres,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('maneuver-list')), findsOneWidget);
    expect(find.text('5 manoeuvres · Fixture route'), findsOneWidget);
    expect(_titles(tester), [
      'Roundabout, 3rd exit, right',
      'Roundabout, 2nd exit, left',
      'Roundabout, 4th exit, left',
      'Turn right',
      'Arrive at the destination',
    ]);
    expect(find.textContaining('from the start'), findsWidgets);
    expect(find.textContaining('exit 3'), findsOneWidget);
    expect(find.text('Gloucester Road · A38'), findsOneWidget);
  });

  testWidgets('the list matches the banner sequence for the same route', (
    tester,
  ) async {
    final route = await routeFromOsrmResponse(multiRoundaboutUrbanResponse());
    final path = route.paths.first.points;

    // Ride the route and collect what the banner announces, in order.
    final announced = <String>[];
    final total = planner
        .instructions(route)
        .map((step) => step.distanceFromStartMeters)
        .reduce((first, second) => first > second ? first : second);
    for (var ridden = 0.0; ridden <= total + 50; ridden += 25) {
      final guidance = planner.plan(
        route: route,
        position: _pointAt(path, ridden),
        progressMeters: ridden,
      );
      final text = guidance?.instruction.text;
      if (text != null && (announced.isEmpty || announced.last != text)) {
        announced.add(text);
      }
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: ManeuverListScreen(
          route: route,
          distanceUnit: DistanceUnit.kilometres,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(announced, isNotEmpty);
    expect(_titles(tester), announced);
  });

  testWidgets('reports how far each manoeuvre is from the rider', (
    tester,
  ) async {
    final route = await routeFromOsrmResponse(multiRoundaboutUrbanResponse());

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: ManeuverListScreen(
          route: route,
          distanceUnit: DistanceUnit.kilometres,
          // Between the first and second roundabout.
          riderPosition: route.paths.first.points[2],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('passed'), findsOneWidget);
    expect(find.textContaining('ahead'), findsWidgets);
  });

  testWidgets('says so plainly when a route carries no instructions', (
    tester,
  ) async {
    final route = ImportedRoute(
      id: 'recorded',
      name: 'Recorded track',
      importedAt: DateTime.utc(2026, 7, 25),
      sourceFileName: 'recorded.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.track,
          points: [
            GeoPoint(latitude: 51.45, longitude: -2.59),
            GeoPoint(latitude: 51.46, longitude: -2.59),
          ],
        ),
      ],
      waypoints: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: ManeuverListScreen(
          route: route,
          distanceUnit: DistanceUnit.kilometres,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('maneuver-list-empty')), findsOneWidget);
    expect(find.byKey(const Key('maneuver-list')), findsNothing);
  });

  testWidgets('shows lane guidance only where the engine supplied lanes', (
    tester,
  ) async {
    final route = await routeFromOsrmResponse(ukRoundaboutStraightOnResponse());

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: ManeuverListScreen(
          route: route,
          distanceUnit: DistanceUnit.kilometres,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Use lane 2: straight'), findsOneWidget);
    // The arrival step has no lanes, so it shows no lane line at all.
    expect(find.textContaining('Use lane'), findsOneWidget);
  });
}

List<String> _titles(WidgetTester tester) => tester
    .widgetList<ListTile>(find.byType(ListTile))
    .map((tile) => (tile.title! as Text).data!)
    .toList(growable: false);

/// A point [meters] along [path], for driving the planner through a route.
GeoPoint _pointAt(List<GeoPoint> path, double meters) {
  var travelled = 0.0;
  for (var index = 0; index < path.length - 1; index += 1) {
    final start = path[index];
    final end = path[index + 1];
    final length = _distanceMeters(start, end);
    if (travelled + length >= meters) {
      final fraction = length == 0 ? 0.0 : (meters - travelled) / length;
      return GeoPoint(
        latitude: start.latitude + (end.latitude - start.latitude) * fraction,
        longitude:
            start.longitude + (end.longitude - start.longitude) * fraction,
      );
    }
    travelled += length;
  }
  return path.last;
}

/// Flat-earth distance, which is accurate enough over a few kilometres to walk
/// a fixture route point by point.
double _distanceMeters(GeoPoint first, GeoPoint second) {
  const metersPerDegree = 111320.0;
  final latitudeDelta = (second.latitude - first.latitude) * metersPerDegree;
  final longitudeDelta =
      (second.longitude - first.longitude) *
      metersPerDegree *
      math.cos(first.latitude * math.pi / 180);
  return math.sqrt(
    latitudeDelta * latitudeDelta + longitudeDelta * longitudeDelta,
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_coordination_mode.dart';
import 'package:ride_relay/domain/ride_plan.dart';

// Synthetic places on a straight line running north. None is anybody's start,
// finish or home.
const _here = GeoPoint(latitude: 52.00, longitude: -1.00);
const _cafe = GeoPoint(latitude: 52.10, longitude: -1.00);
const _pass = GeoPoint(latitude: 52.20, longitude: -1.00);
const _town = GeoPoint(latitude: 52.30, longitude: -1.00);

RidePlanPlace _place(GeoPoint point, String label) =>
    RidePlanPlace(point: point, label: label);

void main() {
  group('the start defaults to the rider\'s location', () {
    test('a plan to a destination starts where the rider is', () {
      final plan = RidePlan.toDestination(_place(_town, 'Town'));

      expect(plan.start, isA<CurrentLocationStart>());
      expect(plan.startsAtCurrentLocation, isTrue);
      expect(plan.stops, isEmpty);
      expect(plan.coordinationMode, RideCoordinationMode.solo);

      final controls = plan.controls(currentLocation: _here)!;
      expect(controls.points, [_here, _town]);
      expect(controls.namedPlaces.first.description, 'Current location');
    });

    test('with no fix yet there is nothing to route, rather than a guess', () {
      final plan = RidePlan.toDestination(_place(_town, 'Town'));

      expect(plan.controls(currentLocation: null), isNull);
    });

    test('a chosen start is used whether or not the rider is located', () {
      final plan = RidePlan.toDestination(
        _place(_town, 'Town'),
      ).withStart(PlaceStart(_place(_cafe, 'Meeting point')));

      expect(plan.startsAtCurrentLocation, isFalse);
      expect(plan.controls()!.points, [_cafe, _town]);
      expect(plan.controls(currentLocation: _here)!.points, [_cafe, _town]);
    });
  });

  group('named stops', () {
    test('a new stop goes just before the destination', () {
      final plan = RidePlan.toDestination(
        _place(_town, 'Town'),
      ).addStop(_place(_cafe, 'Cafe')).addStop(_place(_pass, 'Pass'));

      expect(plan.stops.map((stop) => stop.label), ['Cafe', 'Pass']);
      expect(plan.controls(currentLocation: _here)!.points, [
        _here,
        _cafe,
        _pass,
        _town,
      ]);
    });

    test('stops reorder and remove', () {
      final plan = RidePlan.toDestination(
        _place(_town, 'Town'),
      ).addStop(_place(_cafe, 'Cafe')).addStop(_place(_pass, 'Pass'));

      final moved = plan.moveStop(1, 0);
      expect(moved.stops.map((stop) => stop.label), ['Pass', 'Cafe']);

      final removed = moved.removeStop(0);
      expect(removed.stops.map((stop) => stop.label), ['Cafe']);
    });
  });

  group('shaping points are never stops', () {
    test('a route\'s drawn adjustments come back as shaping points', () {
      final route = _plannedRoute(
        waypoints: [
          _waypoint(_here, 'Start', description: 'Current location'),
          _waypoint(_cafe, 'Cafe'),
          _waypoint(_town, 'Town'),
        ],
        shapingPoints: const [
          RouteShapingPoint(
            id: 'drawn',
            point: GeoPoint(latitude: 52.05, longitude: -1.01),
            legIndex: 0,
          ),
        ],
      );

      final plan = RidePlan.fromRoute(route);

      expect(plan.stops.map((stop) => stop.label), ['Cafe']);
      expect(plan.shapingPoints.single.id, 'drawn');
      expect(plan.shapingPoints.single.legIndex, 0);
    });

    test('an imported GPX shaping point is an adjustment, not a stop', () {
      // `GpxParser` stores `<gpxx:ShapingPoint>` route points as waypoints with
      // this symbol, which is how they came to be listed as stops.
      final route = _plannedRoute(
        waypoints: [
          _waypoint(_here, 'Start'),
          _waypoint(
            const GeoPoint(latitude: 52.05, longitude: -1.01),
            'Shape 1',
            symbol: 'Shaping point',
          ),
          _waypoint(_cafe, 'Cafe', symbol: 'Via point'),
          _waypoint(
            const GeoPoint(latitude: 52.25, longitude: -0.99),
            null,
            symbol: 'Shaping point',
          ),
          _waypoint(_town, 'Town'),
        ],
      );

      final plan = RidePlan.fromRoute(route);

      expect(plan.stops.map((stop) => stop.label), ['Cafe']);
      expect(plan.destination!.label, 'Town');
      expect(plan.shapingPoints.map((point) => point.legIndex), [0, 1]);
      final controls = plan.controls()!;
      expect(controls.namedPlaces.map((place) => place.label), [
        'Start',
        'Cafe',
        'Town',
      ]);
      expect(controls.shapingPointIndexes, {1, 3});
    });

    test('adjustments are routed without splitting a leg', () {
      final plan = RidePlan.toDestination(_place(_town, 'Town'))
          .addStop(_place(_cafe, 'Cafe'))
          .withShapingPoints(const [
            RouteShapingPoint(
              id: 'second-leg',
              point: GeoPoint(latitude: 52.2, longitude: -1.02),
              legIndex: 1,
            ),
            RouteShapingPoint(
              id: 'first-leg',
              point: GeoPoint(latitude: 52.05, longitude: -1.02),
              legIndex: 0,
            ),
          ]);

      final controls = plan.controls(currentLocation: _here)!;

      expect(controls.points, [
        _here,
        const GeoPoint(latitude: 52.05, longitude: -1.02),
        _cafe,
        const GeoPoint(latitude: 52.2, longitude: -1.02),
        _town,
      ]);
      expect(controls.shapingPointIndexes, {1, 3});
      expect(controls.namedPlaces, hasLength(3));
    });
  });

  group('edits keep what the rider drew', () {
    final drawnNearStart = RouteShapingPoint(
      id: 'near-start',
      point: const GeoPoint(latitude: 52.03, longitude: -1.02),
      legIndex: 0,
    );
    final drawnNearEnd = RouteShapingPoint(
      id: 'near-end',
      point: const GeoPoint(latitude: 52.27, longitude: -1.02),
      legIndex: 0,
    );

    test('a stop splits a leg and each adjustment keeps its half', () {
      final plan = RidePlan.toDestination(
        _place(_town, 'Town'),
      ).withShapingPoints([drawnNearStart, drawnNearEnd]);

      final withStop = plan.addStop(
        _place(_pass, 'Pass'),
        currentLocation: _here,
      );

      expect(
        {for (final point in withStop.shapingPoints) point.id: point.legIndex},
        {'near-start': 0, 'near-end': 1},
      );
    });

    test('removing a stop merges its legs and keeps their order', () {
      final plan = RidePlan.toDestination(_place(_town, 'Town'))
          .addStop(_place(_pass, 'Pass'))
          .withShapingPoints([
            drawnNearStart,
            RouteShapingPoint(
              id: 'near-end',
              point: drawnNearEnd.point,
              legIndex: 1,
            ),
          ]);

      final merged = plan.removeStop(0);

      expect(merged.shapingPoints.map((point) => point.id), [
        'near-start',
        'near-end',
      ]);
      expect(merged.shapingPoints.map((point) => point.legIndex), [0, 0]);
    });

    test('moving a stop keeps every adjustment', () {
      final plan = RidePlan.toDestination(_place(_town, 'Town'))
          .addStop(_place(_cafe, 'Cafe'))
          .addStop(_place(_pass, 'Pass'))
          .withShapingPoints([drawnNearStart]);

      final moved = plan.moveStop(0, 1, currentLocation: _here);

      expect(moved.shapingPoints.map((point) => point.id), ['near-start']);
    });

    test('changing either end keeps every adjustment', () {
      final plan = RidePlan.toDestination(
        _place(_town, 'Town'),
      ).withShapingPoints([drawnNearStart, drawnNearEnd]);

      expect(
        plan
            .withStart(PlaceStart(_place(_cafe, 'Meeting point')))
            .withDestination(_place(_pass, 'Pass'))
            .shapingPoints,
        hasLength(2),
      );
    });
  });

  group('dragging a place\'s pin on the map (#891)', () {
    final plan = RidePlan.toDestination(_place(_town, 'Town'))
        .addStop(
          const RidePlanPlace(
            point: _cafe,
            label: 'Cafe',
            symbol: 'Restaurant',
          ),
        )
        .withShapingPoints(const [
          RouteShapingPoint(
            id: 'first-leg',
            point: GeoPoint(latitude: 52.05, longitude: -1.02),
            legIndex: 0,
          ),
          RouteShapingPoint(
            id: 'second-leg',
            point: GeoPoint(latitude: 52.2, longitude: -1.02),
            legIndex: 1,
          ),
        ]);
    // About 55 metres north of the cafe, and about 5.5 km east of it.
    const nudged = GeoPoint(latitude: 52.1005, longitude: -1.00);
    const faraway = GeoPoint(latitude: 52.10, longitude: -0.92);

    test('a stop nudged onto the right road keeps its name and its legs', () {
      final moved = plan.withPlaceMoved(1, nudged, currentLocation: _here);

      expect(moved.stops.single.point, nudged);
      expect(moved.stops.single.label, 'Cafe');
      expect(moved.stops.single.symbol, 'Restaurant');
      expect(
        {for (final point in moved.shapingPoints) point.id: point.legIndex},
        {'first-leg': 0, 'second-leg': 1},
      );
      expect(moved.controls(currentLocation: _here)!.points, [
        _here,
        plan.shapingPoints.first.point,
        nudged,
        plan.shapingPoints.last.point,
        _town,
      ]);
    });

    test('a stop dragged somewhere else becomes a dropped pin', () {
      final moved = plan.withPlaceMoved(1, faraway, currentLocation: _here);

      expect(moved.stops.single.point, faraway);
      expect(moved.stops.single.label, RidePlanPlace.droppedPinLabel);
      expect(moved.stops.single.symbol, isNull);
      expect(moved.shapingPoints, plan.shapingPoints);
    });

    test('dragging "your location" chooses that place as the start', () {
      final moved = plan.withPlaceMoved(0, nudged, currentLocation: _here);

      expect(moved.startsAtCurrentLocation, isFalse);
      expect(moved.resolvedStart()!.point, nudged);
      expect(moved.shapingPoints, plan.shapingPoints);
    });

    test('the destination moves and every adjustment stays', () {
      final moved = plan.withPlaceMoved(2, faraway, currentLocation: _here);

      expect(moved.destination!.point, faraway);
      expect(moved.stops.single.label, 'Cafe');
      expect(moved.shapingPoints, plan.shapingPoints);
      expect(() => plan.withPlaceMoved(3, faraway), throwsRangeError);
    });
  });

  test(
    'what is left of a plan starts here and keeps the legs ahead (#893)',
    () {
      final plan = RidePlan.toDestination(_place(_town, 'Town'))
          .withStart(PlaceStart(_place(_here, 'Meeting point')))
          .addStop(_place(_cafe, 'Cafe'))
          .addStop(_place(_pass, 'Pass'))
          .withShapingPoints(const [
            RouteShapingPoint(
              id: 'ridden',
              point: GeoPoint(latitude: 52.05, longitude: -1.02),
              legIndex: 0,
            ),
            RouteShapingPoint(
              id: 'passed-on-this-leg',
              point: GeoPoint(latitude: 52.12, longitude: -1.02),
              legIndex: 1,
            ),
            RouteShapingPoint(
              id: 'ahead',
              point: GeoPoint(latitude: 52.25, longitude: -1.02),
              legIndex: 2,
            ),
          ]);

      final remaining = plan.remainingFromCurrentLocation(
        passedStops: 1,
        passedShapingPointIds: {'passed-on-this-leg'},
      );

      expect(remaining.startsAtCurrentLocation, isTrue);
      expect(remaining.stops.map((stop) => stop.label), ['Pass']);
      expect(remaining.destination!.label, 'Town');
      expect(
        {for (final point in remaining.shapingPoints) point.id: point.legIndex},
        {'ahead': 1},
      );
    },
  );

  group('reading a confirmed route back', () {
    test(
      'a start from the rider\'s position is still the rider\'s position',
      () {
        final plan = RidePlan.fromRoute(
          _plannedRoute(
            waypoints: [
              _waypoint(_here, 'Start', description: 'Current location'),
              _waypoint(_town, 'Town'),
            ],
          ),
        );

        // Editing mid-ride re-plans from where the rider is now, as Google Maps
        // does.
        expect(plan.startsAtCurrentLocation, isTrue);
        expect(plan.derivedFromGeometry, isFalse);
      },
    );

    test('a chosen start stays that place', () {
      final plan = RidePlan.fromRoute(
        _plannedRoute(
          waypoints: [
            _waypoint(_here, 'Meeting point'),
            _waypoint(_town, 'Town'),
          ],
          preferences: const RoutePreferences(avoidMotorways: true),
        ),
      );

      expect(plan.start, isA<PlaceStart>());
      expect((plan.start as PlaceStart).place.label, 'Meeting point');
      expect(plan.preferences.avoidMotorways, isTrue);
    });

    test('a track\'s scattered points of interest are not a list of stops', () {
      final plan = RidePlan.fromRoute(
        _plannedRoute(
          waypoints: [
            _waypoint(const GeoPoint(latitude: 52.5, longitude: -1.5), 'Pub'),
            _waypoint(const GeoPoint(latitude: 51.7, longitude: -0.5), 'View'),
          ],
        ),
      );

      expect(plan.derivedFromGeometry, isTrue);
      expect(plan.stops, isEmpty);
      expect(plan.controls()!.points, [_here, _town]);
    });

    test('a recording takes its ends from its line', () {
      final plan = RidePlan.fromRoute(_plannedRoute(waypoints: const []));

      expect(plan.derivedFromGeometry, isTrue);
      expect(plan.controls()!.points, [_here, _town]);
    });
  });
}

RouteWaypoint _waypoint(
  GeoPoint point,
  String? name, {
  String? description,
  String? symbol,
}) => RouteWaypoint(
  point: point,
  name: name,
  description: description,
  symbol: symbol,
);

ImportedRoute _plannedRoute({
  required List<RouteWaypoint> waypoints,
  List<RouteShapingPoint> shapingPoints = const [],
  RoutePreferences? preferences,
}) => ImportedRoute(
  id: 'planned',
  name: 'To Town',
  importedAt: DateTime.utc(2026, 10, 4),
  sourceFileName: 'planned.gpx',
  paths: const [
    RoutePath(kind: RoutePathKind.track, points: [_here, _cafe, _pass, _town]),
  ],
  waypoints: waypoints,
  shapingPoints: shapingPoints,
  preferences: preferences,
);

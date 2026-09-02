import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/android_auto_navigation_projection.dart';
import 'package:ride_relay/services/navigation_guidance.dart';
import 'package:ride_relay/services/route_journey_progress.dart';
import 'package:ride_relay/services/route_progress.dart';

void main() {
  test('matches the shared French Android Auto V2 contract fixture', () {
    final expected = jsonDecode(
      File('test/fixtures/android_auto_navigation_v2.json').readAsStringSync(),
    );
    final generatedAt = DateTime.utc(2026, 9, 2, 10, 15);
    const currentManeuver = RouteManeuver(
      position: GeoPoint(latitude: 45.052, longitude: 2.711),
      type: 'roundabout',
      modifier: 'right',
      name: 'Route de Salers',
      ref: 'D 680',
      exitNumber: 3,
      drivingSide: 'right',
      bearingBeforeDegrees: 12,
      bearingAfterDegrees: 112,
      lanes: [
        RouteLane(indications: ['right'], valid: true),
      ],
    );
    const followingManeuver = RouteManeuver(
      position: GeoPoint(latitude: 45.053, longitude: 2.714),
      type: 'turn',
      modifier: 'slight right',
      name: 'D 680',
      drivingSide: 'right',
    );
    const guidance = NavigationGuidance(
      maneuver: currentManeuver,
      distanceMeters: 400,
      instruction: ManeuverInstruction(
        maneuver: currentManeuver,
        kind: ManeuverKind.roundabout,
        direction: ManeuverDirection.right,
        text: '3rd exit, right',
        standaloneText: 'At the roundabout take the 3rd exit, right',
        exitNumber: 3,
        roadName: 'Route de Salers',
        roadRef: 'D 680',
        lanes: [
          RouteLane(indications: ['right'], valid: true),
        ],
        leftHandTraffic: false,
        stepCount: 2,
        departureBearingDegrees: 112,
      ),
      followingManeuver: followingManeuver,
      followingDistanceMeters: 120,
      followingInstruction: ManeuverInstruction(
        maneuver: followingManeuver,
        kind: ManeuverKind.turn,
        direction: ManeuverDirection.slightRight,
        text: 'Keep slight right',
        roadName: 'D 680',
        leftHandTraffic: false,
      ),
    );
    final route = ImportedRoute(
      id: 'france-route',
      name: 'To Puy Mary',
      importedAt: generatedAt,
      sourceFileName: 'puy-mary.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.route,
          points: [
            GeoPoint(latitude: 45.051, longitude: 2.710),
            GeoPoint(latitude: 45.054, longitude: 2.716),
          ],
        ),
      ],
      waypoints: const [],
      maneuvers: const [currentManeuver, followingManeuver],
    );

    final projection = projectAndroidAutoNavigationV2(
      sourceId: 'android-fixture-source',
      sequence: 7,
      generatedAt: generatedAt,
      ridePhase: 'activeRide',
      route: route,
      guidance: guidance,
      distanceUnit: DistanceUnit.kilometres,
      localeIdentifier: 'fr-FR',
      speedMetersPerSecond: 20,
      journeyProgress: RouteJourneyProgress(
        remainingDistanceMeters: 13700,
        remainingTime: const Duration(seconds: 1644),
        arrivalTime: DateTime.fromMillisecondsSinceEpoch(
          1788345744000,
          isUtc: true,
        ),
        nextWaypointName: 'Puy Mary',
        nextWaypointDistanceMeters: 13700,
        nextWaypointArrivalTime: DateTime.fromMillisecondsSinceEpoch(
          1788345744000,
          isUtc: true,
        ),
      ),
      routeProgress: const RouteProgressGeometry(
        riddenPaths: [],
        remainingPaths: [],
        progressMeters: 1200,
        totalMeters: 14900,
      ),
      followRider: true,
      canPlanRoute: false,
      canFreeRoam: false,
      canStartPreparedRide: false,
      alert: const {'message': 'Gravel: high', 'severity': 'high'},
    );

    expect(projection, expected);
  });

  test('keeps ride and navigation lifecycle independent in free roam', () {
    final projection = projectAndroidAutoNavigationV2(
      sourceId: 'free-roam',
      sequence: 1,
      generatedAt: DateTime.utc(2026, 9, 2),
      ridePhase: 'activeRide',
      route: null,
      guidance: null,
      distanceUnit: DistanceUnit.miles,
      localeIdentifier: 'en-GB',
      speedMetersPerSecond: null,
      journeyProgress: null,
      routeProgress: null,
      followRider: true,
      canPlanRoute: true,
      canFreeRoam: false,
      canStartPreparedRide: false,
      alert: null,
    );

    expect(projection['rideLifecycle'], {'phase': 'activeRide'});
    expect(projection['navigationLifecycle'], {
      'phase': 'inactive',
      'shouldOwnNavigation': false,
    });
    expect((projection['actions'] as Map)['canLeaveRide'], isTrue);
    expect((projection['actions'] as Map)['canCancelNavigation'], isFalse);
  });

  test('parses bounded Android host events and rejects malformed payloads', () {
    final event = AndroidAutoNavigationHostEvent.tryParse({
      'type': 'externalDestination',
      'navigationSessionId': 'session-1',
      'routeId': 'route-1',
      'destination': {'latitude': 45.052, 'longitude': 2.711},
      'reason': 'assistant request',
      'projectionSequence': 7,
    });

    expect(event, isNotNull);
    expect(event!.type, AndroidAutoNavigationHostEventType.externalDestination);
    expect(event.navigationSessionId, 'session-1');
    expect(event.routeId, 'route-1');
    expect(event.destination?.latitude, 45.052);
    expect(event.projectionSequence, 7);
    expect(
      AndroidAutoNavigationHostEvent.tryParse({
        'type': 'externalDestination',
        'destination': {'latitude': 95, 'longitude': 2.711},
      }),
      isNull,
    );
    expect(
      AndroidAutoNavigationHostEvent.tryParse({'type': 'notAHostEvent'}),
      isNull,
    );
    expect(
      AndroidAutoNavigationHostEvent.tryParse({
        'type': 'stopped',
        'routeId': 42,
      }),
      isNull,
    );
  });
}

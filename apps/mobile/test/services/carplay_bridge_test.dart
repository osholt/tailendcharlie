import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/hazard.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/geo_point.dart' as presence;
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/domain/rider_color.dart';
import 'package:ride_relay/features/map/motorcycle_icon.dart';
import 'package:ride_relay/services/android_auto_navigation_projection.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/carplay_bridge.dart';
import 'package:ride_relay/services/carplay_route_preview.dart';
import 'package:ride_relay/services/carplay_tec_status.dart';
import 'package:ride_relay/services/leader_ride_status.dart';
import 'package:ride_relay/services/navigation_camera.dart';
import 'package:ride_relay/services/navigation_guidance.dart';
import 'package:ride_relay/services/route_progress.dart';
import 'package:ride_relay/services/route_journey_progress.dart';
import 'package:ride_relay/services/road_routing.dart';
import 'package:ride_relay/services/tec_gap_trend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/carplay');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('publishes a live map snapshot no more than once per second', () async {
    final calls = <MethodCall>[];
    var now = DateTime.utc(2026, 7, 23, 12);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final bridge = CarPlayBridge(
      channel: channel,
      clock: () => now,
      projectionSourceId: 'test-source',
    );
    addTearDown(bridge.dispose);

    Future<void> publish() => bridge.publish(
      session: null,
      riderLocations: const [],
      routeAlerts: const [],
      activeHazards: const [],
      routeName: 'Friday to the Ferry',
      rideState: 'Ride in progress',
      guidanceTitle: 'turn right',
      guidanceDetail: '400 m · A27',
      groupStatus: '5 riders visible',
      markerStatus: 'Marker at the next junction',
    );

    await publish();
    now = now.add(const Duration(milliseconds: 900));
    await publish();
    now = now.add(const Duration(milliseconds: 100));
    await publish();

    expect(calls, hasLength(2));
    expect(calls.every((call) => call.method == 'updateSnapshot'), isTrue);
    expect(calls.first.arguments, {
      'routeId': null,
      'routeName': 'Friday to the Ferry',
      'routePoints': <Object?>[],
      'rideState': 'Ride in progress',
      'surfaceMode': 'activeRide',
      'canPlanRoute': false,
      'canFreeRoam': false,
      'followRider': false,
      'routeProgressMeters': null,
      'routeTotalMeters': null,
      'remainingRoutePoints': <Object?>[],
      'riddenRoutePoints': <Object?>[],
      'journeyProgress': null,
      'carplayNavigation': {
        'schemaVersion': 2,
        'sourceId': 'test-source',
        'sequence': 1,
        'generatedAtMillis': DateTime.utc(
          2026,
          7,
          23,
          12,
        ).millisecondsSinceEpoch,
        'rideLifecycle': {'phase': 'activeRide'},
        'navigationLifecycle': {'phase': 'inactive'},
        'trip': null,
        'currentManeuver': null,
        'followingManeuver': null,
        'journey': null,
        'units': {'distance': null, 'speed': null},
        'localeIdentifier': null,
      },
      'androidAutoNavigation': {
        'schemaVersion': 2,
        'sourceId': 'test-source',
        'sequence': 1,
        'generatedAtMillis': DateTime.utc(
          2026,
          7,
          23,
          12,
        ).millisecondsSinceEpoch,
        'rideLifecycle': {'phase': 'activeRide'},
        'navigationLifecycle': {
          'phase': 'inactive',
          'shouldOwnNavigation': false,
        },
        'route': null,
        'currentManeuver': null,
        'followingManeuver': null,
        'journey': null,
        'progress': {'travelledMeters': null, 'totalMeters': null},
        'units': {'distance': null, 'speed': null},
        'localeIdentifier': null,
        'camera': {'followRider': false},
        'actions': {
          'canPlanRoute': false,
          'canFreeRoam': false,
          'canStartPreparedRide': false,
          'canCancelNavigation': false,
          'canLeaveRide': true,
        },
        'alert': null,
      },
      'guidanceTitle': 'turn right',
      'guidanceDetail': '400 m · A27',
      'guidanceRoadName': null,
      'guidanceDistanceMeters': null,
      // Null here because this snapshot has neither a distance nor a speed. It is
      // never 0: zero tells CarPlay the rider is arriving now (#452).
      'guidanceSecondsRemaining': null,
      'distanceUnit': null,
      'localeIdentifier': null,
      'groupStatus': '5 riders visible',
      'markerStatus': 'Marker at the next junction',
      'marker': null,
      'tec': {
        'state': 'none',
        'riderId': null,
        'name': null,
        'headline': 'No TEC',
        'detail': 'Nobody is covering the back',
        'distanceMeters': null,
        'etaSeconds': null,
        'locationAgeSeconds': null,
        'trend': 'unknown',
        'trendLabel': null,
      },
      'tecRequest': null,
      'rideStart': null,
      'speed': null,
      'basemap': null,
      'updatedAtMillis': DateTime.utc(2026, 7, 23, 12).millisecondsSinceEpoch,
      'riders': <Object?>[],
      'alert': null,
    });
  });

  test('publishes the phone speed and mapped limit presentation', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    final bridge = CarPlayBridge(channel: channel);
    addTearDown(bridge.dispose);

    await bridge.publish(
      session: null,
      riderLocations: const [],
      routeAlerts: const [],
      activeHazards: const [],
      localSpeedMetersPerSecond: 10,
      localSpeedIsAgeing: true,
      speedLimitEnabled: true,
      speedLimitStatus: 'known',
      speedLimitMilesPerHour: 30,
    );

    expect((received!.arguments as Map)['speed'], {
      'metresPerSecond': 10.0,
      'isAgeing': true,
      'limitStatus': 'known',
      'limitMilesPerHour': 30,
      'limitUnlimited': false,
    });
  });

  test('projects the phone home map and saved rider identity', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    final bridge = CarPlayBridge(channel: channel);
    addTearDown(bridge.dispose);

    await bridge.publish(
      session: null,
      riderLocations: const [],
      routeAlerts: const [],
      activeHazards: const [],
      surfaceMode: CarPlaySurfaceMode.home,
      canPlanRoute: true,
      canFreeRoam: true,
      showTecStatus: false,
      followRider: true,
      localPosition: const GeoPoint(latitude: 51.46, longitude: -2.51),
      localRider: const CarPlayLocalRider(
        riderId: 'installation-1',
        displayName: 'Oliver',
        motorcycleStyle: MotorcycleIconStyle.scrambler,
        riderSymbol: RiderSymbol.emoji('🦊'),
        riderColor: RiderColor.purple,
      ),
    );

    final snapshot = received!.arguments as Map;
    expect(snapshot['surfaceMode'], 'home');
    expect(snapshot['canPlanRoute'], isTrue);
    expect(snapshot['canFreeRoam'], isTrue);
    expect(snapshot['tec'], isNull);
    expect(snapshot['localRider'], {
      'riderId': 'installation-1',
      'label': 'Oliver',
      'isLocal': true,
      'role': 'Rider',
      'riderSymbol': 'emoji:🦊',
      'motorcycleStyle': 'scrambler',
      'riderColor': 'purple',
      'latitude': 51.46,
      'longitude': -2.51,
      'headingDegrees': null,
    });
  });

  test('publishes a bounded prepared-ride start action', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    final bridge = CarPlayBridge(channel: channel);
    addTearDown(bridge.dispose);

    await bridge.publish(
      session: null,
      riderLocations: const [],
      routeAlerts: const [],
      activeHazards: const [],
      rideStart: const CarPlayRideStart(
        enabled: true,
        detail: 'Friday route. Recording, sharing and navigation will start.',
        warning: 'No Tail End Charlie is assigned.',
      ),
    );

    expect((received!.arguments as Map)['rideStart'], {
      'enabled': true,
      'detail': 'Friday route. Recording, sharing and navigation will start.',
      'warning': 'No Tail End Charlie is assigned.',
      'unavailableReason': null,
    });
  });

  test('projected phone handoffs are platform-safe', () {
    final carPlay = projectedLocationUnavailableReason(
      ProjectedHostPlatform.carPlay,
    );
    final androidAuto = projectedLocationUnavailableReason(
      ProjectedHostPlatform.androidAuto,
    );

    expect(carPlay, contains('CarPlay'));
    expect(carPlay.toLowerCase(), isNot(contains('phone')));
    expect(androidAuto, contains('safely parked'));
    expect(androidAuto, contains('on your phone'));
    expect(androidAuto, isNot(contains('iPhone')));
    expect(androidAuto, isNot(contains('CarPlay')));
  });

  test('offers prepared-ride start only to an eligible leader', () {
    CarPlayRideStart? project({
      bool hasSession = true,
      bool isLeader = true,
      bool rideStarted = false,
      bool rideEnded = false,
      bool busy = false,
      bool locationReady = true,
      bool isGroup = false,
      bool hasTec = false,
      ProjectedHostPlatform? hostPlatform,
    }) => CarPlayRideStart.project(
      hasSession: hasSession,
      isLeader: isLeader,
      rideStarted: rideStarted,
      rideEnded: rideEnded,
      busy: busy,
      locationReady: locationReady,
      isGroup: isGroup,
      hasTec: hasTec,
      hostPlatform: hostPlatform,
    );

    expect(project(hasSession: false), isNull);
    expect(project(isLeader: false), isNull);
    expect(project(rideStarted: true), isNull);
    expect(project(rideEnded: true), isNull);

    final carPlayPermission = project(
      locationReady: false,
      hostPlatform: ProjectedHostPlatform.carPlay,
    )!;
    expect(carPlayPermission.enabled, isFalse);
    expect(
      carPlayPermission.unavailableReason,
      contains('cannot start from CarPlay'),
    );
    expect(
      carPlayPermission.unavailableReason!.toLowerCase(),
      isNot(contains('phone')),
    );

    final androidPermission = project(
      locationReady: false,
      hostPlatform: ProjectedHostPlatform.androidAuto,
    )!;
    expect(androidPermission.unavailableReason, contains('safely parked'));
    expect(androidPermission.unavailableReason, contains('on your phone'));
    expect(androidPermission.unavailableReason, isNot(contains('iPhone')));
    expect(androidPermission.unavailableReason, isNot(contains('CarPlay')));

    final saving = project(busy: true)!;
    expect(saving.enabled, isFalse);
    expect(saving.unavailableReason, contains('still being saved'));

    final solo = project()!;
    expect(solo.enabled, isTrue);
    expect(solo.warning, isNull);

    final groupWithoutTec = project(isGroup: true)!;
    expect(groupWithoutTec.warning, contains('No Tail End Charlie'));
    expect(project(isGroup: true, hasTec: true)!.warning, isNull);
  });

  test(
    'a prepared-ride action appearing and disappearing jumps the throttle',
    () async {
      final calls = <MethodCall>[];
      var now = DateTime.utc(2026, 8, 3, 12);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final bridge = CarPlayBridge(channel: channel, clock: () => now);
      addTearDown(bridge.dispose);

      Future<void> publish({CarPlayRideStart? rideStart}) => bridge.publish(
        session: null,
        riderLocations: const [],
        routeAlerts: const [],
        activeHazards: const [],
        rideStart: rideStart,
      );

      await publish();
      now = now.add(const Duration(milliseconds: 100));
      await publish(
        rideStart: const CarPlayRideStart(
          enabled: true,
          detail: 'No route selected. Recording and sharing will start.',
        ),
      );
      now = now.add(const Duration(milliseconds: 100));
      await publish();

      expect(calls, hasLength(3));
      expect((calls[1].arguments as Map)['rideStart'], isNotNull);
      expect((calls[2].arguments as Map)['rideStart'], isNull);
    },
  );

  test('retries immediately after a native snapshot failure', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls += 1;
      if (calls == 1) {
        throw PlatformException(code: 'carplay_unavailable');
      }
      return null;
    });
    final bridge = CarPlayBridge(
      channel: channel,
      clock: () => DateTime.utc(2026, 8, 3, 12),
    );
    addTearDown(bridge.dispose);

    Future<void> publish() => bridge.publish(
      session: null,
      riderLocations: const [],
      routeAlerts: const [],
      activeHazards: const [],
    );

    await publish();
    await publish();

    expect(calls, 2);
  });

  test(
    'projects the longest route path for the native navigation map',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final bridge = CarPlayBridge(channel: channel);
      addTearDown(bridge.dispose);
      final route = ImportedRoute(
        id: 'route-42',
        name: 'Friday to the Ferry',
        importedAt: DateTime.utc(2026, 7, 29),
        sourceFileName: 'friday.gpx',
        paths: const [
          RoutePath(
            kind: RoutePathKind.route,
            points: [
              GeoPoint(latitude: 51.45, longitude: -2.58),
              GeoPoint(latitude: 51.451, longitude: -2.58),
            ],
          ),
          RoutePath(
            kind: RoutePathKind.track,
            points: [
              GeoPoint(latitude: 51.45, longitude: -2.58),
              GeoPoint(latitude: 51.46, longitude: -2.57),
              GeoPoint(latitude: 51.47, longitude: -2.56),
            ],
          ),
        ],
        waypoints: const [],
      );

      await bridge.publish(
        session: null,
        riderLocations: const [],
        routeAlerts: const [],
        activeHazards: const [],
        route: route,
        routeName: route.name,
        followRider: true,
        guidanceTitle: 'Turn left',
        guidanceRoadName: 'A420',
        guidanceDistanceMeters: 275,
        distanceUnit: DistanceUnit.miles,
      );

      final arguments = Map<String, Object?>.from(
        calls.single.arguments as Map,
      );
      expect(arguments['routeId'], 'route-42');
      expect(arguments['followRider'], isTrue);
      expect(arguments['guidanceRoadName'], 'A420');
      expect(arguments['guidanceDistanceMeters'], 275);
      // The estimate the car's ETA card renders. Present because this call
      // supplies a speed; null rather than 0 when it cannot be computed (#452).
      expect(
        arguments['guidanceSecondsRemaining'],
        anyOf(isNull, isA<double>()),
      );
      expect(arguments['distanceUnit'], 'miles');
      expect(arguments['routePoints'], [
        {'latitude': 51.45, 'longitude': -2.58},
        {'latitude': 51.46, 'longitude': -2.57},
        {'latitude': 51.47, 'longitude': -2.56},
      ]);
    },
  );

  test(
    'adds typed CarPlay navigation without changing legacy fields',
    () async {
      MethodCall? received;
      final now = DateTime.utc(2026, 9, 2, 10, 15);
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return null;
      });
      final bridge = CarPlayBridge(
        channel: channel,
        clock: () => now,
        projectionSourceId: 'projection-test',
      );
      addTearDown(bridge.dispose);

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
        importedAt: now,
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

      await bridge.publish(
        session: null,
        riderLocations: const [],
        routeAlerts: const [],
        activeHazards: const [],
        route: route,
        routeName: route.name,
        rideState: 'Ride in progress',
        surfaceMode: CarPlaySurfaceMode.activeRide,
        navigationGuidance: guidance,
        guidanceTitle: guidance.instruction.standaloneText,
        guidanceRoadName: guidance.roadLabel,
        guidanceDistanceMeters: guidance.distanceMeters,
        distanceUnit: DistanceUnit.kilometres,
        localeIdentifier: 'fr-FR',
        localSpeedMetersPerSecond: 20,
      );

      final snapshot = Map<String, Object?>.from(received!.arguments as Map);
      final projection = Map<String, Object?>.from(
        snapshot['carplayNavigation']! as Map,
      );
      expect(projection['schemaVersion'], 2);
      expect(projection['sourceId'], 'projection-test');
      expect(projection['sequence'], 1);
      expect(projection['rideLifecycle'], {'phase': 'activeRide'});
      expect(projection['navigationLifecycle'], {'phase': 'navigating'});
      expect(projection['localeIdentifier'], 'fr-FR');
      expect(projection['units'], {
        'distance': 'kilometres',
        'speed': 'kilometresPerHour',
      });
      expect(projection['trip'], {
        'id': 'france-route',
        'routeChoiceId': 'france-route:primary',
        'name': 'To Puy Mary',
        'trafficSide': 'right',
      });
      final current = Map<String, Object?>.from(
        projection['currentManeuver']! as Map,
      );
      expect(current['id'], currentManeuver.identity);
      expect(current['kind'], 'roundabout');
      expect(current['direction'], 'right');
      expect(current['exitNumber'], 3);
      expect(current['trafficSide'], 'right');
      expect(current['distanceMeters'], 400);
      expect(current['secondsRemaining'], 20);
      expect(current['instructionVariants'], [
        '3rd exit, right',
        'At the roundabout take the 3rd exit, right',
      ]);
      expect(current['roadNameVariants'], [
        'Route de Salers · D 680',
        'Route de Salers',
        'D 680',
      ]);
      expect(current['lanes'], [
        {
          'indications': ['right'],
          'valid': true,
        },
      ]);
      expect(
        (projection['followingManeuver'] as Map)['id'],
        followingManeuver.identity,
      );

      // The existing shared snapshot remains intact until Android Auto moves to
      // its own V2 adapter.
      expect(snapshot['guidanceTitle'], guidance.instruction.standaloneText);
      expect(snapshot['guidanceRoadName'], guidance.roadLabel);
      expect(snapshot['guidanceDistanceMeters'], 400);
      expect(snapshot['distanceUnit'], 'kilometres');
    },
  );

  test('projects route progress for matching CarPlay route styling', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    final bridge = CarPlayBridge(channel: channel);
    addTearDown(bridge.dispose);

    await bridge.publish(
      session: null,
      riderLocations: const [],
      routeAlerts: const [],
      activeHazards: const [],
      routeProgress: const RouteProgressGeometry(
        riddenPaths: [
          [
            GeoPoint(latitude: 51.45, longitude: -2.58),
            GeoPoint(latitude: 51.46, longitude: -2.57),
          ],
        ],
        remainingPaths: [
          [
            GeoPoint(latitude: 51.46, longitude: -2.57),
            GeoPoint(latitude: 51.47, longitude: -2.56),
          ],
        ],
        progressMeters: 1200,
        totalMeters: 2500,
      ),
    );

    final arguments = Map<String, Object?>.from(received!.arguments as Map);
    expect(arguments['routeProgressMeters'], 1200);
    expect(arguments['routeTotalMeters'], 2500);
    expect(arguments['riddenRoutePoints'], [
      {'latitude': 51.45, 'longitude': -2.58},
      {'latitude': 51.46, 'longitude': -2.57},
    ]);
    expect(arguments['remainingRoutePoints'], [
      {'latitude': 51.46, 'longitude': -2.57},
      {'latitude': 51.47, 'longitude': -2.56},
    ]);
  });

  test('projects route and next-stop estimates for CarPlay', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    final bridge = CarPlayBridge(channel: channel);
    addTearDown(bridge.dispose);
    final arrival = DateTime.utc(2026, 8, 14, 15, 42);
    final waypointArrival = DateTime.utc(2026, 8, 14, 15, 20);

    await bridge.publish(
      session: null,
      riderLocations: const [],
      routeAlerts: const [],
      activeHazards: const [],
      distanceUnit: DistanceUnit.miles,
      journeyProgress: RouteJourneyProgress(
        remainingDistanceMeters: 16093.44,
        remainingTime: const Duration(minutes: 42),
        arrivalTime: arrival,
        nextWaypointName: 'Chippenham',
        nextWaypointDistanceMeters: 8046.72,
        nextWaypointArrivalTime: waypointArrival,
      ),
    );

    final arguments = Map<String, Object?>.from(received!.arguments as Map);
    expect(arguments['journeyProgress'], {
      'remainingDistanceMeters': 16093.44,
      'remainingSeconds': 2520,
      'arrivalTimeMillis': arrival.millisecondsSinceEpoch,
      'nextWaypointName': 'Chippenham',
      'nextWaypointDistanceMeters': 8046.72,
      'nextWaypointArrivalTimeMillis': waypointArrival.millisecondsSinceEpoch,
    });
  });

  test(
    'publishes the phone navigation viewport without snapshot lag',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final bridge = CarPlayBridge(channel: channel);
      addTearDown(bridge.dispose);

      await bridge.publishViewport(
        const NavigationCameraViewport(
          latitude: 51.46,
          longitude: -2.57,
          zoom: 15.25,
          tilt: 42,
          bearing: 123,
          sourceViewportHeightPixels: 760,
          sourceViewportWidthPixels: 390,
          riderViewportFraction: 0.7,
          riderHorizontalViewportFraction: 2 / 3,
          leftHandTraffic: true,
          mapStyleUrl: 'https://tiles.example.com/day',
          mapStyleJson: '{"version":8,"sources":{},"layers":[]}',
          mapStyleDark: false,
        ),
      );

      expect(calls.first.method, 'updateMapStyle');
      expect(calls.first.arguments, {
        'styleJson': '{"version":8,"sources":{},"layers":[]}',
        'fallbackStyleUrl': 'https://tiles.example.com/day',
        'dark': false,
      });
      expect(calls.last.method, 'updateViewport');
      expect(calls.last.arguments, {
        'latitude': 51.46,
        'longitude': -2.57,
        'zoom': 15.25,
        'tilt': 42,
        'bearing': 123,
        'sourceViewportHeightPixels': 760,
        'sourceViewportWidthPixels': 390,
        'riderViewportFraction': 0.7,
        'riderHorizontalViewportFraction': 2 / 3,
        'leftHandTraffic': true,
        'mapStyleUrl': 'https://tiles.example.com/day',
        'mapStyleDark': false,
      });
    },
  );

  test('publishes the phone rider symbol and identity colour', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    final bridge = CarPlayBridge(channel: channel);
    addTearDown(bridge.dispose);
    final now = DateTime.utc(2026, 8, 3, 12);

    await bridge.publish(
      session: null,
      riderLocations: [
        RiderLocation(
          riderId: 'oliver',
          displayName: 'Oliver Holt',
          role: RideRole.rider,
          sample: LocationSample(
            position: const presence.GeoPoint(
              latitude: 51.45,
              longitude: -2.58,
            ),
            recordedAt: now,
            accuracyMeters: 6,
          ),
          receivedAt: now,
          motorcycleStyle: MotorcycleIconStyle.cafeRacer,
          riderSymbol: const RiderSymbol.initials(
            customInitials: 'OH',
            initialsInk: RiderInitialsInk.purple,
          ),
          riderColor: RiderColor.white,
        ),
      ],
      routeAlerts: const [],
      activeHazards: const [],
    );

    final rider =
        ((received!.arguments as Map)['riders'] as List).single as Map;
    expect(rider['riderSymbol'], 'initials:v1:T0g:purple');
    expect(rider['motorcycleStyle'], 'cafeRacer');
    expect(rider['riderColor'], 'white');
  });

  test('publishes structured junction marker mode for the turn card', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    final bridge = CarPlayBridge(channel: channel);
    addTearDown(bridge.dispose);

    await bridge.publish(
      session: null,
      riderLocations: const [],
      routeAlerts: const [],
      activeHazards: const [],
      markerStatus: 'Wait for Tail End Charlie.',
      marker: const CarPlayMarkerStatus(
        stage: 'tecApproaching',
        title: 'TEC approaching',
        detail: '4/4 riders passed · TEC 0.2 mi away',
        ridersPassed: 4,
        ridersExpected: 4,
        tecDistanceMeters: 322,
      ),
    );

    expect((received!.arguments as Map)['marker'], {
      'stage': 'tecApproaching',
      'title': 'TEC approaching',
      'detail': '4/4 riders passed · TEC 0.2 mi away',
      'ridersPassed': 4,
      'ridersExpected': 4,
      'tecDistanceMeters': 322.0,
    });
  });

  test(
    'projects a self-contained local rider and resolved map style',
    () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return null;
      });
      final bridge = CarPlayBridge(channel: channel);
      addTearDown(bridge.dispose);
      final joinedAt = DateTime.utc(2026, 8, 3, 12);

      await bridge.publish(
        session: RideSession(
          rideId: 'ride-1',
          rideCode: '123456',
          inviteSecret: 'secret',
          joinToken: 'token',
          localRiderId: 'oliver',
          displayName: 'Oliver Holt',
          role: RideRole.lead,
          joinedAt: joinedAt,
          riderSymbol: const RiderSymbol.initials(),
          riderColor: RiderColor.orange,
        ),
        riderLocations: const [],
        routeAlerts: const [],
        activeHazards: const [],
        basemap: const BasemapConfiguration(
          styleUrl: 'https://tiles.example.com/day',
        ),
        mapStyleJson: '{"version":8,"sources":{},"layers":[]}',
        localPosition: const GeoPoint(latitude: 51.45, longitude: -2.58),
        localHeadingDegrees: 123,
      );

      final snapshot = received!.arguments as Map;
      expect(
        (snapshot['basemap'] as Map)['styleJson'],
        contains('"version":8'),
      );
      expect(snapshot['localPosition'], {
        'latitude': 51.45,
        'longitude': -2.58,
        'headingDegrees': 123.0,
      });
      expect(snapshot['localRider'], {
        'riderId': 'oliver',
        'label': 'Oliver Holt',
        'isLocal': true,
        'role': 'Lead',
        'riderSymbol': 'initials',
        'motorcycleStyle': 'adventureTourer',
        'riderColor': 'orange',
        'latitude': 51.45,
        'longitude': -2.58,
        'headingDegrees': 123.0,
      });
    },
  );

  test('replays the latest style and viewport when CarPlay connects', () async {
    final calls = <MethodCall>[];
    var refreshes = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final bridge = CarPlayBridge(
      channel: channel,
      onStateRequested: () async {
        refreshes += 1;
      },
    );
    addTearDown(bridge.dispose);

    await bridge.publishViewport(
      const NavigationCameraViewport(
        latitude: 51.45,
        longitude: -2.58,
        zoom: 15,
        tilt: 30,
        bearing: 90,
        sourceViewportHeightPixels: 760,
        sourceViewportWidthPixels: 390,
        riderViewportFraction: 0.7,
        riderHorizontalViewportFraction: 2 / 3,
        leftHandTraffic: false,
        mapStyleUrl: 'https://tiles.example.com/day',
        mapStyleJson: '{"version":8,"sources":{},"layers":[]}',
        mapStyleDark: false,
      ),
    );
    calls.clear();

    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('requestState')),
      (_) {},
    );

    expect(refreshes, 1);
    expect(calls.map((call) => call.method), [
      'updateMapStyle',
      'updateViewport',
    ]);
  });

  // Issue #128: one rider self-selects the role, the leader asks another, and
  // both carry RideRole.tailEndCharlie in the journal. The phone map already
  // resolves that to one back-marker; a head unit showing two is telling the
  // leader the group has two backs.
  test('marks only the effective back-marker as Tail End Charlie', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    final bridge = CarPlayBridge(channel: channel);
    addTearDown(bridge.dispose);
    final now = DateTime.utc(2026, 8, 2, 12);
    RiderLocation holder(String riderId, String displayName) => RiderLocation(
      riderId: riderId,
      displayName: displayName,
      role: RideRole.tailEndCharlie,
      sample: LocationSample(
        position: const presence.GeoPoint(latitude: 51.45, longitude: -2.58),
        recordedAt: now,
        accuracyMeters: 6,
      ),
      receivedAt: now,
    );

    await bridge.publish(
      session: null,
      riderLocations: [holder('bill', 'Bill'), holder('dave', 'Dave')],
      routeAlerts: const [],
      activeHazards: const [],
      effectiveTecRiderIds: const {'dave'},
    );

    final riders = (received!.arguments as Map)['riders'] as List;
    final byName = {
      for (final rider in riders.cast<Map>()) rider['label']: rider,
    };
    expect(byName['Dave']!['isTec'], isTrue);
    expect(byName['Dave']!['role'], 'Tail End Charlie');
    expect(byName['Bill']!['isTec'], isFalse);
    expect(byName['Bill']!['role'], 'Rider');
  });

  // A caller that has not resolved a back-marker must not have its riders
  // silently demoted: an empty set means "not resolved", not "nobody".
  test('leaves the journal role alone when no TEC has been resolved', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    final bridge = CarPlayBridge(channel: channel);
    addTearDown(bridge.dispose);
    final now = DateTime.utc(2026, 8, 2, 12);

    await bridge.publish(
      session: null,
      riderLocations: [
        RiderLocation(
          riderId: 'bill',
          displayName: 'Bill',
          role: RideRole.tailEndCharlie,
          sample: LocationSample(
            position: const presence.GeoPoint(
              latitude: 51.45,
              longitude: -2.58,
            ),
            recordedAt: now,
            accuracyMeters: 6,
          ),
          receivedAt: now,
        ),
      ],
      routeAlerts: const [],
      activeHazards: const [],
    );

    final riders = (received!.arguments as Map)['riders'] as List;
    expect((riders.single as Map)['role'], 'Tail End Charlie');
    expect((riders.single as Map)['isTec'], isFalse);
  });

  test('publishes the resolved back-marker beside the rider list', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    final bridge = CarPlayBridge(channel: channel);
    addTearDown(bridge.dispose);

    await bridge.publish(
      session: null,
      riderLocations: const [],
      routeAlerts: const [],
      activeHazards: const [],
      tec: const CarPlayTecStatus(
        availability: TecAvailability.tracking,
        riderId: 'dave',
        name: 'Dave',
        distanceMeters: 1931,
        estimatedTime: Duration(minutes: 3),
        trend: TecGapTrend.closing,
      ),
    );

    final tec = (received!.arguments as Map)['tec'] as Map;
    expect(tec['state'], 'tracking');
    expect(tec['headline'], 'TEC · 1.2 mi · ~3 min ↓');
    expect(tec['detail'], 'Dave · 1.2 mi · about 3 min · ↓ Closing');
  });

  // A leader asking at a fuel stop is standing there waiting, and an alert left
  // up after the question has gone is asking a rider to agree to something no
  // longer on offer. Both directions therefore jump the ordinary throttle.
  test('a TEC request and its withdrawal both jump the throttle', () async {
    final calls = <MethodCall>[];
    var now = DateTime.utc(2026, 8, 2, 12);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    final bridge = CarPlayBridge(channel: channel, clock: () => now);
    addTearDown(bridge.dispose);

    Future<void> publish({CarPlayTecRequest? request}) => bridge.publish(
      session: null,
      riderLocations: const [],
      routeAlerts: const [],
      activeHazards: const [],
      tecRequest: request,
    );

    await publish();
    now = now.add(const Duration(milliseconds: 100));
    // No request either time: the ordinary throttle still applies.
    await publish();
    expect(calls, hasLength(1));

    now = now.add(const Duration(milliseconds: 100));
    await publish(
      request: const CarPlayTecRequest(requestId: 'req-1', leaderName: 'Sam'),
    );
    expect(calls, hasLength(2));

    now = now.add(const Duration(milliseconds: 100));
    // The same request again is not news.
    await publish(
      request: const CarPlayTecRequest(requestId: 'req-1', leaderName: 'Sam'),
    );
    expect(calls, hasLength(2));

    now = now.add(const Duration(milliseconds: 100));
    await publish();
    expect(calls, hasLength(3));
    expect((calls.last.arguments as Map)['tecRequest'], isNull);

    final request = (calls[1].arguments as Map)['tecRequest'] as Map;
    expect(request['requestId'], 'req-1');
    expect(request['title'], 'Be Tail End Charlie?');
    expect(
      request['message'],
      'Sam has asked you to ride at the back and keep the group together.',
    );
  });

  // #321: the head unit renders with the phone's own MapLibre styles so it
  // shares the tile cache and survives a signal drop. Both styles travel as
  // fallbacks, alongside the exact style selected on the phone.
  test('carries both basemap styles to the head unit', () async {
    MethodCall? received;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });
    final bridge = CarPlayBridge(channel: channel);
    addTearDown(bridge.dispose);

    await bridge.publish(
      session: null,
      riderLocations: const [],
      routeAlerts: const [],
      activeHazards: const [],
      basemap: const BasemapConfiguration(
        styleUrl: 'https://tiles.example.com/day',
        darkStyleUrl: 'https://tiles.example.com/night',
      ),
    );

    expect((received!.arguments as Map)['basemap'], {
      'styleUrl': 'https://tiles.example.com/day',
      'darkStyleUrl': 'https://tiles.example.com/night',
      'selectedStyleUrl': 'https://tiles.example.com/day',
      'dark': false,
    });
  });

  test(
    'a dark phone still publishes the canonical CarPlay day style',
    () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return null;
      });
      final bridge = CarPlayBridge(channel: channel);
      addTearDown(bridge.dispose);
      const configured = BasemapConfiguration(
        styleUrl: 'https://tiles.example.com/day',
        darkStyleUrl: 'https://tiles.example.com/night',
      );

      await bridge.publish(
        session: null,
        riderLocations: const [],
        routeAlerts: const [],
        activeHazards: const [],
        basemap: configured.forBrightness(dark: true),
        mapStyleJson: '{"version":8,"sources":{},"layers":[]}',
      );

      expect((received!.arguments as Map)['basemap'], {
        'styleUrl': 'https://tiles.example.com/day',
        'darkStyleUrl': 'https://tiles.example.com/night',
        'selectedStyleUrl': 'https://tiles.example.com/night',
        'dark': true,
        'styleJson': '{"version":8,"sources":{},"layers":[]}',
      });
    },
  );

  // A build that configures only one style must not leave the car with an
  // empty URL and a blank map in whichever mode it happens to be in.
  test(
    'falls back to the day style when no dark style is configured',
    () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return null;
      });
      final bridge = CarPlayBridge(channel: channel);
      addTearDown(bridge.dispose);

      await bridge.publish(
        session: null,
        riderLocations: const [],
        routeAlerts: const [],
        activeHazards: const [],
        basemap: const BasemapConfiguration(
          styleUrl: 'https://tiles.example.com/day',
        ),
      );

      expect((received!.arguments as Map)['basemap'], {
        'styleUrl': 'https://tiles.example.com/day',
        'darkStyleUrl': 'https://tiles.example.com/day',
        'selectedStyleUrl': 'https://tiles.example.com/day',
        'dark': false,
      });
    },
  );

  test('names the role rather than a rider when the leader is unknown', () {
    const request = CarPlayTecRequest(requestId: 'req-1', leaderName: null);

    expect(
      request.message,
      'The ride leader has asked you to ride at the back and keep the group '
      'together.',
    );
  });

  // Accepting puts a rider on the back of the group. An answer this phone
  // cannot identify is dropped rather than guessed at.
  test('relays a well-formed answer and drops a malformed one', () async {
    final answers = <(String, bool)>[];
    final bridge = CarPlayBridge(
      channel: channel,
      onTecRoleAnswered: (requestId, accepted) async {
        answers.add((requestId, accepted));
      },
    );
    addTearDown(bridge.dispose);

    Future<void> answer(Object? arguments) => messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(
        MethodCall('answerTecRoleRequest', arguments),
      ),
      (_) {},
    );

    await answer({'requestId': 'req-1', 'accepted': true});
    await answer({'requestId': 'req-2', 'accepted': false});
    await answer({'requestId': '', 'accepted': true});
    await answer({'accepted': true});
    await answer({'requestId': 'req-3'});
    await answer('req-4');

    expect(answers, [('req-1', true), ('req-2', false)]);
  });

  test('relays only rider-reportable CarPlay hazards', () async {
    final reports = <HazardType>[];
    final bridge = CarPlayBridge(
      channel: channel,
      onHazardReported: (type) async => reports.add(type),
    );
    addTearDown(bridge.dispose);

    Future<void> report(Object? arguments) => messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall('reportHazard', arguments)),
      (_) {},
    );

    await report({'type': 'speedCamera'});
    await report({'type': 'policeActivity'});
    await report({'type': 'other'});
    await report({'type': 'notARealHazard'});
    await report({'type': 42});
    await report('pothole');

    expect(reports, [
      HazardType.speedCamera,
      HazardType.policeActivity,
      HazardType.other,
    ]);
  });

  test('relays a confirmed prepared-ride start request', () async {
    var starts = 0;
    final bridge = CarPlayBridge(
      channel: channel,
      onRideStartRequested: () async {
        starts += 1;
      },
    );
    addTearDown(bridge.dispose);

    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('startPreparedRide')),
      (_) {},
    );

    expect(starts, 1);
  });

  test('relays a CarPlay-confirmed leave request to the ride owner', () async {
    var leaves = 0;
    final bridge = CarPlayBridge(
      channel: channel,
      onLeaveRequested: () async {
        leaves += 1;
      },
    );
    addTearDown(bridge.dispose);

    await messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(const MethodCall('leaveRide')),
      (_) {},
    );

    expect(leaves, 1);
  });

  test(
    'every unavailable vehicle action returns an in-CarPlay result',
    () async {
      final bridge = CarPlayBridge(channel: channel);
      addTearDown(bridge.dispose);

      final responses = <Object?>[
        await invokeDartChannel(
          messenger,
          channel,
          const MethodCall('triggerEmergency'),
        ),
        await invokeDartChannel(
          messenger,
          channel,
          const MethodCall('leaveRide'),
        ),
        await invokeDartChannel(
          messenger,
          channel,
          const MethodCall('startPreparedRide'),
        ),
        await invokeDartChannel(
          messenger,
          channel,
          const MethodCall('reportHazard', {'type': 'other'}),
        ),
        await invokeDartChannel(
          messenger,
          channel,
          const MethodCall('answerTecRoleRequest', {
            'requestId': 'request-1',
            'accepted': true,
          }),
        ),
      ];

      for (final response in responses.cast<Map>()) {
        expect(response['ok'], isFalse);
        final error = (response['error'] as String).toLowerCase();
        expect(error, isNot(contains('phone')));
        expect(error, isNot(contains('unlock')));
      }
    },
  );

  test(
    'vehicle cancellation ends directions without leaving the ride',
    () async {
      var navigationCancellations = 0;
      var leaves = 0;
      final bridge = CarPlayBridge(
        channel: channel,
        onNavigationCancelRequested: () async {
          navigationCancellations += 1;
        },
        onLeaveRequested: () async {
          leaves += 1;
        },
      );
      addTearDown(bridge.dispose);

      final response = await invokeDartChannel(
        messenger,
        channel,
        const MethodCall('cancelNavigation'),
      );

      expect(response, {'ok': true, 'error': null});
      expect(navigationCancellations, 1);
      expect(leaves, 0);
    },
  );

  test('searches only a submitted CarPlay destination query', () async {
    final queries = <String>[];
    final bridge = CarPlayBridge(
      channel: channel,
      onDestinationSearch: (query) async {
        queries.add(query);
        return const [
          CarPlayDestination(
            label: 'Chippenham, Wiltshire',
            point: GeoPoint(latitude: 51.46, longitude: -2.12),
          ),
        ];
      },
    );
    addTearDown(bridge.dispose);

    final response = await invokeDartChannel(
      messenger,
      channel,
      const MethodCall('searchDestinations', {'query': '  Chippenham  '}),
    );

    expect(queries, ['Chippenham']);
    expect(response, {
      'results': [
        {
          'label': 'Chippenham, Wiltshire',
          'latitude': 51.46,
          'longitude': -2.12,
        },
      ],
      'error': null,
    });
  });

  test('relays an exact destination, ride type, and free-roam start', () async {
    final plans = <(CarPlayDestination, bool?)>[];
    var freeRoamStarts = 0;
    final bridge = CarPlayBridge(
      channel: channel,
      onDestinationSelected: (destination, groupRide) async {
        plans.add((destination, groupRide));
      },
      onFreeRoamRequested: () async {
        freeRoamStarts += 1;
      },
    );
    addTearDown(bridge.dispose);

    final planned = await invokeDartChannel(
      messenger,
      channel,
      const MethodCall('planDestination', {
        'label': 'Chippenham, Wiltshire',
        'latitude': 51.46,
        'longitude': -2.12,
        'groupRide': true,
      }),
    );
    final invalid = await invokeDartChannel(
      messenger,
      channel,
      const MethodCall('planDestination', {
        'label': 'Invalid',
        'latitude': 95,
        'longitude': -2.12,
      }),
    );
    final freeRoam = await invokeDartChannel(
      messenger,
      channel,
      const MethodCall('startFreeRoam'),
    );

    expect(planned, {'ok': true, 'error': null});
    expect(invalid, {
      'ok': false,
      'error': 'That destination is invalid. Search again.',
    });
    expect(plans, hasLength(1));
    expect(plans.single.$1.label, 'Chippenham, Wiltshire');
    expect(plans.single.$1.point.latitude, 51.46);
    expect(plans.single.$2, isTrue);
    expect(freeRoam, {'ok': true, 'error': null});
    expect(freeRoamStarts, 1);
  });

  test('previews, commits, and cancels a CarPlay route transaction', () async {
    final transaction = CarPlayRoutePreviewTransaction();
    final commits = <String>[];
    final cancellations = <String>[];
    final plan = DestinationRoutePlan(
      route: ImportedRoute(
        id: 'route-1',
        name: 'To Puy Mary',
        importedAt: DateTime.utc(2026, 9, 2),
        sourceFileName: 'route-1.gpx',
        paths: const [
          RoutePath(
            kind: RoutePathKind.track,
            points: [
              GeoPoint(latitude: 45.05, longitude: 2.7),
              GeoPoint(latitude: 45.06, longitude: 2.72),
            ],
          ),
        ],
        waypoints: const [],
      ),
      distanceMeters: 12000,
      duration: const Duration(minutes: 20),
    );
    final bridge = CarPlayBridge(
      channel: channel,
      onDestinationPreviewRequested: (destination) async {
        final preview = CarPlayTripPreview.single(
          destinationLabel: destination.label,
          plan: plan,
        );
        transaction.replace(preview);
        return preview;
      },
      onDestinationPreviewCommitted: (previewId, routeChoiceId) async {
        final selected = transaction.commit(
          previewId: previewId,
          routeChoiceId: routeChoiceId,
        );
        commits.add(selected.route.id);
      },
      onDestinationPreviewCancelled: (previewId) async {
        cancellations.add(previewId);
        transaction.cancel(previewId);
      },
    );
    addTearDown(bridge.dispose);

    final previewed = await invokeDartChannel(
      messenger,
      channel,
      const MethodCall('previewDestination', {
        'label': 'Puy Mary, France',
        'latitude': 45.06,
        'longitude': 2.72,
      }),
    );
    final committed = await invokeDartChannel(
      messenger,
      channel,
      const MethodCall('commitDestinationPreview', {
        'previewId': 'route-1:carplay-preview',
        'routeChoiceId': 'route-1:primary',
      }),
    );
    final duplicate = await invokeDartChannel(
      messenger,
      channel,
      const MethodCall('commitDestinationPreview', {
        'previewId': 'route-1:carplay-preview',
        'routeChoiceId': 'route-1:primary',
      }),
    );
    final cancelled = await invokeDartChannel(
      messenger,
      channel,
      const MethodCall('cancelDestinationPreview', {
        'previewId': 'route-1:carplay-preview',
      }),
    );

    final previewMap = previewed as Map;
    expect(previewMap['error'], isNull);
    expect((previewMap['preview'] as Map)['id'], 'route-1:carplay-preview');
    expect(((previewMap['preview'] as Map)['choices'] as List), hasLength(1));
    expect(committed, {'ok': true, 'error': null});
    expect(duplicate, {
      'ok': false,
      'error': 'That route preview has expired. Choose the destination again.',
    });
    expect(cancelled, {'ok': true, 'error': null});
    expect(commits, ['route-1']);
    expect(cancellations, ['route-1:carplay-preview']);
  });

  test(
    'relays a typed Android Auto host event without a ride command',
    () async {
      final events = <AndroidAutoNavigationHostEvent>[];
      final bridge = CarPlayBridge(
        channel: channel,
        onAndroidAutoNavigationHostEvent: (event) async => events.add(event),
      );
      addTearDown(bridge.dispose);

      final response = await invokeDartChannel(
        messenger,
        channel,
        const MethodCall('androidAutoNavigationEvent', {
          'type': 'stopped',
          'navigationSessionId': 'route-1:android-navigation',
          'routeId': 'route-1',
          'reason': 'hostNavigationTookOwnership',
          'projectionSequence': 8,
        }),
      );

      expect(response, {'ok': true, 'error': null});
      expect(events, hasLength(1));
      expect(events.single.type, AndroidAutoNavigationHostEventType.stopped);
      expect(events.single.routeId, 'route-1');
      expect(events.single.reason, 'hostNavigationTookOwnership');
      expect(events.single.projectionSequence, 8);
    },
  );

  test('a retiring surface cannot clear the next surface handler', () async {
    var firstStarts = 0;
    var secondStarts = 0;
    final first = CarPlayBridge(
      channel: channel,
      onFreeRoamRequested: () async => firstStarts += 1,
    );
    final second = CarPlayBridge(
      channel: channel,
      onFreeRoamRequested: () async => secondStarts += 1,
    );
    addTearDown(second.dispose);

    // Mirrors Flutter's child replacement: the new shell has already installed
    // its handler when the old shell is finally unmounted.
    await first.dispose();
    final response = await invokeDartChannel(
      messenger,
      channel,
      const MethodCall('startFreeRoam'),
    );

    expect(response, {'ok': true, 'error': null});
    expect(firstStarts, 0);
    expect(secondStarts, 1);
  });
}

Future<Object?> invokeDartChannel(
  TestDefaultBinaryMessenger messenger,
  MethodChannel channel,
  MethodCall call,
) {
  final response = Completer<Object?>();
  messenger.handlePlatformMessage(
    channel.name,
    channel.codec.encodeMethodCall(call),
    (data) {
      response.complete(
        data == null ? null : channel.codec.decodeEnvelope(data),
      );
    },
  );
  return response.future;
}

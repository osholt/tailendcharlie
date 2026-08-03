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
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/carplay_bridge.dart';
import 'package:ride_relay/services/carplay_tec_status.dart';
import 'package:ride_relay/services/leader_ride_status.dart';
import 'package:ride_relay/services/navigation_camera.dart';
import 'package:ride_relay/services/route_progress.dart';
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
    final bridge = CarPlayBridge(channel: channel, clock: () => now);
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
      'followRider': false,
      'routeProgressMeters': null,
      'routeTotalMeters': null,
      'remainingRoutePoints': <Object?>[],
      'riddenRoutePoints': <Object?>[],
      'guidanceTitle': 'turn right',
      'guidanceDetail': '400 m · A27',
      'guidanceRoadName': null,
      'guidanceDistanceMeters': null,
      'distanceUnit': null,
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
      'basemap': null,
      'updatedAtMillis': DateTime.utc(2026, 7, 23, 12).millisecondsSinceEpoch,
      'riders': <Object?>[],
      'alert': null,
    });
  });

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
      expect(arguments['distanceUnit'], 'miles');
      expect(arguments['routePoints'], [
        {'latitude': 51.45, 'longitude': -2.58},
        {'latitude': 51.46, 'longitude': -2.57},
        {'latitude': 51.47, 'longitude': -2.56},
      ]);
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
          mapStyleUrl: 'https://tiles.example.com/day',
          mapStyleJson: '{"version":8,"sources":{},"layers":[]}',
        ),
      );

      expect(calls.first.method, 'updateMapStyle');
      expect(calls.first.arguments, {
        'styleJson': '{"version":8,"sources":{},"layers":[]}',
        'fallbackStyleUrl': 'https://tiles.example.com/day',
      });
      expect(calls.last.method, 'updateViewport');
      expect(calls.last.arguments, {
        'latitude': 51.46,
        'longitude': -2.57,
        'zoom': 15.25,
        'tilt': 42,
        'bearing': 123,
        'sourceViewportHeightPixels': 760,
        'mapStyleUrl': 'https://tiles.example.com/day',
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
          riderSymbol: const RiderSymbol.initials(),
          riderColor: RiderColor.orange,
        ),
      ],
      routeAlerts: const [],
      activeHazards: const [],
    );

    final rider =
        ((received!.arguments as Map)['riders'] as List).single as Map;
    expect(rider['riderSymbol'], 'initials');
    expect(rider['motorcycleStyle'], 'cafeRacer');
    expect(rider['riderColor'], 'orange');
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
        mapStyleUrl: 'https://tiles.example.com/day',
        mapStyleJson: '{"version":8,"sources":{},"layers":[]}',
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
    expect(tec['headline'], 'TEC · 1.2 mi ↓');
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
    });
  });

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
}

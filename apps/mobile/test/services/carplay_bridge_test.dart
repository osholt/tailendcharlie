import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/carplay_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/carplay');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'publishes a Driving Task snapshot no more than every ten seconds',
    () async {
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
      now = now.add(const Duration(seconds: 9));
      await publish();
      now = now.add(const Duration(seconds: 1));
      await publish();

      expect(calls, hasLength(2));
      expect(calls.every((call) => call.method == 'updateSnapshot'), isTrue);
      expect(calls.first.arguments, {
        'routeId': null,
        'routeName': 'Friday to the Ferry',
        'routePoints': <Object?>[],
        'rideState': 'Ride in progress',
        'guidanceTitle': 'turn right',
        'guidanceDetail': '400 m · A27',
        'guidanceRoadName': null,
        'guidanceDistanceMeters': null,
        'groupStatus': '5 riders visible',
        'markerStatus': 'Marker at the next junction',
        'updatedAtMillis': DateTime.utc(2026, 7, 23, 12).millisecondsSinceEpoch,
        'riders': <Object?>[],
        'alert': null,
      });
    },
  );

  test(
    'projects the longest route path for the native navigation map',
    () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
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
        guidanceTitle: 'Turn left',
        guidanceRoadName: 'A420',
        guidanceDistanceMeters: 275,
      );

      final arguments = Map<String, Object?>.from(received!.arguments as Map);
      expect(arguments['routeId'], 'route-42');
      expect(arguments['guidanceRoadName'], 'A420');
      expect(arguments['guidanceDistanceMeters'], 275);
      expect(arguments['routePoints'], [
        {'latitude': 51.45, 'longitude': -2.58},
        {'latitude': 51.46, 'longitude': -2.57},
        {'latitude': 51.47, 'longitude': -2.56},
      ]);
    },
  );
}

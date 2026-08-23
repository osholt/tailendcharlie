import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/foreground_location_controller.dart';
import 'package:ride_relay/controllers/map_style_mode_controller.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/controllers/spoken_guidance_controller.dart';
import 'package:ride_relay/domain/distance_unit.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/geo_point.dart' as rider_domain;
import 'package:ride_relay/controllers/shared_route_controller.dart'
    show PendingInAppRoute;
import 'package:ride_relay/domain/imported_route.dart'
    show GeoPoint, ImportedRoute, RouteManeuver, RoutePath, RoutePathKind;
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/features/home/home_map_backdrop.dart';
import 'package:ride_relay/features/map/ride_map_feature.dart';
import 'package:ride_relay/domain/route_authority.dart';
import 'package:ride_relay/services/device_location_source.dart';
import 'package:ride_relay/services/navigation_guidance.dart';
import 'package:ride_relay/services/spoken_guidance.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late MapStyleModeController mapStyleMode;
  late SpeedLimitDisplayController speedLimitDisplay;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    mapStyleMode = await MapStyleModeController.load();
    speedLimitDisplay = SpeedLimitDisplayController.inMemory();
  });

  Future<void> pump(
    WidgetTester tester, {
    required ForegroundLocationController location,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HomeMapBackdrop(
          mapStyleMode: mapStyleMode,
          speedLimitDisplay: speedLimitDisplay,
          distanceUnit: DistanceUnit.kilometres,
          enableNativeServices: false,
          locationController: location,
        ),
      ),
    ),
  );

  testWidgets('opening the app never asks for location (#405)', (tester) async {
    // The whole point of opening on the map is that it is useful before the
    // rider has decided anything. Meeting them with a permission prompt before
    // the app has shown what it is for would trade one gate for another.
    final platform = _RecordingLocationPlatform();
    final location = ForegroundLocationController(
      DeviceLocationSource(platform),
      (_) async {},
    );
    addTearDown(location.dispose);

    await pump(tester, location: location);
    await tester.pumpAndSettle();

    expect(
      platform.permissionRequests,
      0,
      reason: 'the backdrop must resume, never request, on open',
    );
    expect(find.byKey(const Key('home-show-my-location')), findsOneWidget);
  });

  testWidgets('the rider can ask for their location themselves', (
    tester,
  ) async {
    final platform = _RecordingLocationPlatform();
    final location = ForegroundLocationController(
      DeviceLocationSource(platform),
      (_) async {},
    );
    addTearDown(location.dispose);

    await pump(tester, location: location);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-show-my-location')));
    await tester.pumpAndSettle();

    expect(platform.permissionRequests, 1);
  });

  testWidgets('a rider who already granted access is not asked again', (
    tester,
  ) async {
    final platform = _RecordingLocationPlatform(
      granted: DeviceLocationPermission.always,
    );
    addTearDown(platform.closeStreams);
    final location = ForegroundLocationController(
      DeviceLocationSource(platform),
      (_) async {},
    );
    addTearDown(location.dispose);

    await pump(tester, location: location);
    await tester.pumpAndSettle();

    expect(platform.permissionRequests, 0);
  });

  testWidgets('free roam preserves the complete navigation fix (#655)', (
    tester,
  ) async {
    final platform = _RecordingLocationPlatform(
      granted: DeviceLocationPermission.always,
    );
    addTearDown(platform.closeStreams);
    final location = ForegroundLocationController(
      DeviceLocationSource(platform),
      (_) async {},
    );
    addTearDown(location.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeMapBackdrop(
            mapStyleMode: mapStyleMode,
            speedLimitDisplay: speedLimitDisplay,
            distanceUnit: DistanceUnit.kilometres,
            locationController: location,
          ),
        ),
      ),
    );
    await tester.pump();

    final recordedAt = DateTime.utc(2026, 8, 23, 14, 30);
    platform.emit(
      LocationSample(
        position: const rider_domain.GeoPoint(
          latitude: 51.46765,
          longitude: -2.50679,
        ),
        recordedAt: recordedAt,
        accuracyMeters: 4.5,
        speedMetersPerSecond: 13.25,
        headingDegrees: 287,
      ),
    );
    await tester.pump();

    final map = tester.widget<RideMapFeature>(
      find.byKey(const Key('home-map')),
    );
    final fix = map.navigationPosition?.value;
    expect(fix, isNotNull);
    expect(fix!.point.latitude, 51.46765);
    expect(fix.point.longitude, -2.50679);
    expect(fix.recordedAt, recordedAt);
    expect(fix.speedMetersPerSecond, 13.25);
    expect(fix.headingDegrees, 287);
    expect(fix.accuracyMeters, 4.5);
  });

  testWidgets('Where To navigation is saved automatically when it stops', (
    tester,
  ) async {
    final platform = _RecordingLocationPlatform(
      granted: DeviceLocationPermission.always,
    );
    addTearDown(platform.closeStreams);
    final location = ForegroundLocationController(
      DeviceLocationSource(platform),
      (_) async {},
    );
    addTearDown(location.dispose);
    final archive = InMemoryCompletedRideStore();
    CompletedRide? archived;
    var navigating = false;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => HomeMapBackdrop(
            mapStyleMode: mapStyleMode,
            speedLimitDisplay: speedLimitDisplay,
            distanceUnit: DistanceUnit.kilometres,
            locationController: location,
            completedRideStore: archive,
            localDisplayName: 'Oliver',
            navigating: navigating,
            onRouteChanged: (route) =>
                setState(() => navigating = route != null),
            onNavigationArchived: (ride) => archived = ride,
          ),
        ),
      ),
    );
    await tester.pump();

    final route = ImportedRoute(
      id: 'where-to',
      name: 'To Tuckers Grave',
      importedAt: DateTime.utc(2026, 8, 23),
      sourceFileName: 'where-to.gpx',
      paths: const [
        RoutePath(
          kind: RoutePathKind.route,
          points: [
            GeoPoint(latitude: 51.4627, longitude: -2.5084),
            GeoPoint(latitude: 51.2949, longitude: -2.3579),
          ],
        ),
      ],
      waypoints: const [],
    );
    tester
        .widget<RideMapFeature>(find.byKey(const Key('home-map')))
        .onRouteChanged!(route);
    await tester.pump();

    final start = DateTime.utc(2026, 8, 23, 10);
    platform.emit(
      LocationSample(
        position: const rider_domain.GeoPoint(
          latitude: 51.4627,
          longitude: -2.5084,
        ),
        recordedAt: start,
        accuracyMeters: 4,
        speedMetersPerSecond: 10,
        headingDegrees: 120,
      ),
    );
    await tester.pump();
    platform.emit(
      LocationSample(
        position: const rider_domain.GeoPoint(
          latitude: 51.4617,
          longitude: -2.5064,
        ),
        recordedAt: start.add(const Duration(seconds: 10)),
        accuracyMeters: 4,
        speedMetersPerSecond: 10,
        headingDegrees: 120,
      ),
    );
    await tester.pump();

    tester
        .widget<RideMapFeature>(find.byKey(const Key('home-map')))
        .onRouteChanged!(null);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final stored = await archive.list();
    expect(stored, hasLength(1));
    expect(stored.single.title, 'To Tuckers Grave');
    expect(stored.single.traveledRoute?.paths.single.points, hasLength(2));
    expect(identical(archived, stored.single), isTrue);
  });

  testWidgets('free-roam navigation speaks the guidance shown on the map', (
    tester,
  ) async {
    final engine = _RecordingSpokenEngine();
    final spoken = SpokenGuidanceController.inMemory(
      enabled: true,
      engine: () => engine,
    );
    addTearDown(spoken.dispose);
    final platform = _RecordingLocationPlatform(
      granted: DeviceLocationPermission.always,
    );
    addTearDown(platform.closeStreams);
    final location = ForegroundLocationController(
      DeviceLocationSource(platform),
      (_) async {},
    );
    addTearDown(location.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeMapBackdrop(
          mapStyleMode: mapStyleMode,
          speedLimitDisplay: speedLimitDisplay,
          spokenGuidance: spoken,
          distanceUnit: DistanceUnit.kilometres,
          locationController: location,
          navigating: true,
        ),
      ),
    );
    await tester.pump();
    platform.emit(
      LocationSample(
        position: const rider_domain.GeoPoint(
          latitude: 51.46765,
          longitude: -2.50679,
        ),
        recordedAt: DateTime.utc(2026, 8, 23, 15),
        accuracyMeters: 4,
        speedMetersPerSecond: 10,
        headingDegrees: 270,
      ),
    );
    await tester.pump();

    const maneuver = RouteManeuver(
      position: GeoPoint(latitude: 51.46765, longitude: -2.5070),
      type: 'turn',
      modifier: 'left',
      name: 'Station Road',
    );
    const guidance = NavigationGuidance(
      maneuver: maneuver,
      distanceMeters: 20,
      instruction: ManeuverInstruction(
        maneuver: maneuver,
        kind: ManeuverKind.turn,
        direction: ManeuverDirection.left,
        text: 'Turn left',
        standaloneText: 'Turn left onto Station Road',
      ),
    );
    final map = tester.widget<RideMapFeature>(
      find.byKey(const Key('home-map')),
    );
    map.onNavigationGuidanceChanged!(guidance);
    await tester.pump();

    expect(engine.spoken, ['Turn left onto Station Road']);
  });
  testWidgets('the free-roam map is the rider\'s own, not a follower\'s (#576)', (
    tester,
  ) async {
    // This backdrop used to pass `canEditRoute: false` — the flag that means
    // "somebody else leads this ride". There is no ride here and no leader, so
    // every route action inherited a refusal with no group behind it: adding a
    // café in free roam failed with "Only the ride leader can replace the group
    // route". The authority is the assertion because it is the thing that was
    // wrong; what it permits is covered in ride_map_feature_test.dart.
    final platform = _RecordingLocationPlatform();
    final location = ForegroundLocationController(
      DeviceLocationSource(platform),
      (_) async {},
    );
    addTearDown(location.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeMapBackdrop(
            mapStyleMode: mapStyleMode,
            speedLimitDisplay: speedLimitDisplay,
            distanceUnit: DistanceUnit.kilometres,
            locationController: location,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester
          .widget<RideMapFeature>(find.byKey(const Key('home-map')))
          .routeAuthority,
      RouteAuthority.personal,
    );
  });

  testWidgets('free roam follows a route without a ride to hold it (#600)', (
    tester,
  ) async {
    // The whole of #600 in one assertion. Free roam used to answer "where do
    // you want to go" by creating a ride — a coordination mode, a code, a
    // lobby — because the map only turned its guidance on for a ride that had
    // started. The route arrives here on its own now, and the map is told it
    // is navigating without any ride being true.
    final platform = _RecordingLocationPlatform();
    final location = ForegroundLocationController(
      DeviceLocationSource(platform),
      (_) async {},
    );
    addTearDown(location.dispose);
    final token = Object();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeMapBackdrop(
            mapStyleMode: mapStyleMode,
            speedLimitDisplay: speedLimitDisplay,
            distanceUnit: DistanceUnit.kilometres,
            locationController: location,
            pendingInAppRoute: PendingInAppRoute(
              route: ImportedRoute(
                id: 'bath',
                name: 'Bath, Somerset',
                importedAt: DateTime.utc(2026, 8, 17, 9),
                sourceFileName: 'search',
                paths: const [
                  RoutePath(
                    kind: RoutePathKind.route,
                    points: [
                      GeoPoint(latitude: 51.44, longitude: -2.58),
                      GeoPoint(latitude: 51.38, longitude: -2.36),
                    ],
                  ),
                ],
                waypoints: const [],
              ),
              reviewNotes: const ['Toll road avoided.'],
            ),
            changeRouteRequestToken: token,
            navigating: true,
          ),
        ),
      ),
    );
    await tester.pump();

    final map = tester.widget<RideMapFeature>(
      find.byKey(const Key('home-map')),
    );
    expect(map.pendingInAppRoute?.route.name, 'Bath, Somerset');
    expect(map.pendingInAppRoute?.reviewNotes, ['Toll road avoided.']);
    // Without the token the map treats the route as one it has already taken
    // and never opens the review.
    expect(map.changeRouteRequestToken, same(token));
    // Navigating, and no ride: the two used to be the same flag, so guidance
    // out here was only reachable by creating one.
    expect(map.navigating, isTrue);
    expect(map.rideStarted, isFalse);
  });

  // #572, #573.
  group(
    'the host hands its top band to the map rather than painting over it',
    () {
      HostMapChrome chrome() => HostMapChrome(
        title: const Text('Where to?'),
        actions: [
          IconButton(
            key: const Key('host-settings'),
            tooltip: 'Settings',
            onPressed: () {},
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      );

      testWidgets('the map is given the chrome, not covered by it', (
        tester,
      ) async {
        final platform = _RecordingLocationPlatform();
        final location = ForegroundLocationController(
          DeviceLocationSource(platform),
          (_) async {},
        );
        addTearDown(location.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HomeMapBackdrop(
                mapStyleMode: mapStyleMode,
                speedLimitDisplay: speedLimitDisplay,
                distanceUnit: DistanceUnit.kilometres,
                locationController: location,
                hostChrome: chrome(),
              ),
            ),
          ),
        );
        await tester.pump();

        expect(
          tester
              .widget<RideMapFeature>(find.byKey(const Key('home-map')))
              .hostChrome,
          isNotNull,
          reason: 'painting it over the map is what buried the layer menu',
        );
      });

      testWidgets('a build with no platform map keeps its search field and its '
          'way into Settings', (tester) async {
        // The chrome reaches riders through the map's AppBar now. A build
        // without the platform plugins must not therefore lose it entirely.
        final platform = _RecordingLocationPlatform();
        final location = ForegroundLocationController(
          DeviceLocationSource(platform),
          (_) async {},
        );
        addTearDown(location.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: HomeMapBackdrop(
              mapStyleMode: mapStyleMode,
              speedLimitDisplay: speedLimitDisplay,
              distanceUnit: DistanceUnit.kilometres,
              enableNativeServices: false,
              locationController: location,
              hostChrome: chrome(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Where to?'), findsOneWidget);
        expect(find.byKey(const Key('host-settings')), findsOneWidget);
        expect(
          tester
              .getRect(find.text('Where to?'))
              .overlaps(tester.getRect(find.byKey(const Key('host-settings')))),
          isFalse,
        );
      });
    },
  );

  // #577. Free roam lost the rider's position and offered no way back: the
  // recovery control was hidden on `sharing`, which says only that sampling
  // was requested, and nothing restarted the sampler after a background trip.
  group('free roam can be found again without restarting the app', () {
    testWidgets('resuming from the background restarts the sampler', (
      tester,
    ) async {
      final platform = _RecordingLocationPlatform(
        granted: DeviceLocationPermission.always,
      );
      addTearDown(platform.closeStreams);
      // The controller's own restart is exercised by the ride shell, which has
      // called it since #205. What was missing here, and all this asserts, is
      // that free roam asks for it at all.
      final location = _RecordingLocationController(
        DeviceLocationSource(platform),
        (_) async {},
      );
      addTearDown(location.dispose);

      await pump(tester, location: location);
      await tester.pumpAndSettle();
      expect(location.restarts, 0);

      // Through the binding, so forgetting `addObserver` fails here too.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(
        location.restarts,
        1,
        reason:
            'free roam had no lifecycle observer at all, which is why '
            'only quitting the app recovered a lost position',
      );
    });

    testWidgets(
      'a sampler that has produced no fix still offers the way back',
      (tester) async {
        // The precise reported state: sharing is on, so the old rule hid the
        // control, but there is no rider on the map and search will not start.
        final platform = _RecordingLocationPlatform(
          granted: DeviceLocationPermission.always,
        );
        final location = ForegroundLocationController(
          DeviceLocationSource(platform),
          (_) async {},
        );
        addTearDown(location.dispose);

        await pump(tester, location: location);
        await tester.pumpAndSettle();

        expect(location.sharing, isTrue, reason: 'the sampler is running');
        expect(find.byKey(const Key('home-show-my-location')), findsOneWidget);
      },
    );

    testWidgets('a rider who is on the map is not nagged to be found', (
      tester,
    ) async {
      final platform = _RecordingLocationPlatform(
        granted: DeviceLocationPermission.always,
      );
      addTearDown(platform.closeStreams);
      final position = ValueNotifier<GeoPoint?>(null);
      addTearDown(position.dispose);
      final location = ForegroundLocationController(
        DeviceLocationSource(platform),
        (_) async {},
      );
      addTearDown(location.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeMapBackdrop(
              mapStyleMode: mapStyleMode,
              speedLimitDisplay: speedLimitDisplay,
              distanceUnit: DistanceUnit.kilometres,
              enableNativeServices: false,
              locationController: location,
              position: position,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('home-show-my-location')), findsOneWidget);

      position.value = const GeoPoint(latitude: 51.46, longitude: -2.59);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('home-show-my-location')), findsNothing);
    });
  });
}

class _RecordingSpokenEngine implements SpokenGuidanceEngine {
  final spoken = <String>[];

  @override
  Future<void> configure() async {}

  @override
  Future<void> speak(String phrase) async => spoken.add(phrase);

  @override
  Future<void> stop() async {}
}

/// Records that the backdrop asked for a restart, without standing up the
/// platform stream machinery an actual restart would need. Whether a restart
/// works is `ForegroundLocationController`'s business; whether free roam asks
/// for one is this widget's, and is what #577 was.
class _RecordingLocationController extends ForegroundLocationController {
  _RecordingLocationController(super.source, super.onSample);

  int restarts = 0;

  @override
  Future<void> restartAfterForegroundResume() async => restarts += 1;
}

/// Counts prompts. The test is about *when* a prompt happens, so the count is
/// the assertion rather than an incidental detail.
class _RecordingLocationPlatform implements DeviceLocationPlatform {
  _RecordingLocationPlatform({this.granted = DeviceLocationPermission.denied});

  final DeviceLocationPermission granted;
  int permissionRequests = 0;

  @override
  Future<bool> isServiceEnabled() async => true;

  @override
  Future<DeviceLocationPermission> checkPermission() async => granted;

  @override
  Future<DeviceLocationPermission> requestPermission() async {
    permissionRequests += 1;
    return granted;
  }

  @override
  Future<DeviceLocationPermission> requestBackgroundPermission() async {
    permissionRequests += 1;
    return granted;
  }

  /// Counts how many times a native stream was created. A restart is a new
  /// subscription, which is the observable difference (#577).
  int streamSubscriptions = 0;
  final _streams = <StreamController<LocationSample>>[];

  /// Open and silent, which is the state under test: a live subscription that
  /// has delivered nothing. `Stream.empty()` completes at once, and the source
  /// then leaves `sampling` — the opposite of the case being reproduced.
  @override
  Stream<LocationSample> positionStream() {
    streamSubscriptions += 1;
    final controller = StreamController<LocationSample>();
    _streams.add(controller);
    return controller.stream;
  }

  void emit(LocationSample sample) {
    for (final controller in _streams) {
      controller.add(sample);
    }
  }

  Future<void> closeStreams() async {
    for (final controller in _streams) {
      await controller.close();
    }
  }
}

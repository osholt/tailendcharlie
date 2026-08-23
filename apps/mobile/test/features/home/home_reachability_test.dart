import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/completed_rides_controller.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/map_style_mode_controller.dart';
import 'package:ride_relay/controllers/ride_diagnostics_controller.dart';
import 'package:ride_relay/controllers/ride_code_preference_controller.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/controllers/rider_profile_controller.dart';
import 'package:ride_relay/controllers/shared_route_controller.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/controllers/spoken_guidance_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/data/ride_diagnostics_log_store.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/rider_color.dart';
import 'package:ride_relay/domain/recorded_route_store.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/features/home/home_map_backdrop.dart';
import 'package:ride_relay/features/home/home_screen.dart';
import 'package:ride_relay/features/map/motorcycle_icon.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every way into the app, by the words a rider can read (#306).
///
/// "Features that exist but cannot be found are not delivered." QR joining
/// shipped in #279 and was then reported as missing, because its only
/// affordance was an unlabelled icon with a tooltip — and a tooltip does not
/// appear when you tap a phone. "Ride again" (#251) went the same way.
///
/// These assert the journeys #306 names by their **label**, not by a key or an
/// icon, so a consolidation that moves them has to keep them findable. They are
/// deliberately written before the reorganisation rather than after it: their
/// job is to be the safety net it lands into.
void main() {
  late InMemoryEventStore eventStore;
  late RideController rideController;
  late DistanceUnitController distanceUnits;
  late MapStyleModeController mapStyleMode;
  late RideCodePreferenceController rideCodePreference;
  late RiderProfileController riderProfile;
  late SharedRouteController sharedRoutes;
  late SpeedLimitDisplayController speedLimitDisplay;
  late CompletedRidesController completedRides;
  late SpokenGuidanceController spokenGuidance;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    eventStore = InMemoryEventStore();
    var id = 0;
    rideController = RideController(
      eventStore,
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 8, 2, 9),
      idFactory: () => 'id-${id++}',
      random: Random(7),
      rideCodeDirectory: _NullRideCodeDirectory(),
    );
    await rideController.initialize();
    distanceUnits = DistanceUnitController.forLocale(const Locale('en', 'GB'));
    mapStyleMode = await MapStyleModeController.load();
    rideCodePreference = await RideCodePreferenceController.load();
    riderProfile = await RiderProfileController.load();
    sharedRoutes = await SharedRouteController.load(planDirectory: null);
    speedLimitDisplay = SpeedLimitDisplayController.inMemory();
    completedRides = await CompletedRidesController.load(
      _EmptyCompletedRideStore(),
    );
    spokenGuidance = SpokenGuidanceController.inMemory(enabled: true);
  });

  tearDown(() {
    rideController.dispose();
    distanceUnits.dispose();
    mapStyleMode.dispose();
    rideCodePreference.dispose();
    riderProfile.dispose();
    sharedRoutes.dispose();
    speedLimitDisplay.dispose();
    completedRides.dispose();
    spokenGuidance.dispose();
  });

  Future<void> pumpHome(
    WidgetTester tester, {
    RideDiagnosticsController? rideDiagnostics,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: HomeScreen(
          controller: rideController,
          distanceUnits: distanceUnits,
          mapStyleMode: mapStyleMode,
          rideCodePreference: rideCodePreference,
          riderProfile: riderProfile,
          sharedRoutes: sharedRoutes,
          speedLimitDisplay: speedLimitDisplay,
          spokenGuidance: spokenGuidance,
          rideDiagnostics: rideDiagnostics,
          recordedRoutes: InMemoryRecordedRouteStore(),
          completedRides: completedRides,
          // The home map backdrop is live in production. Without this it would
          // wait forever here on a platform map and a location plugin that
          // never answer, and pumpAndSettle would time out.
          enableNativeServices: false,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the home map receives the rider\'s spoken-guidance setting', (
    tester,
  ) async {
    await pumpHome(tester);

    final map = tester.widget<HomeMapBackdrop>(find.byType(HomeMapBackdrop));
    expect(identical(map.spokenGuidance, spokenGuidance), isTrue);
  });

  testWidgets('the home map receives the diagnostics lifecycle controller', (
    tester,
  ) async {
    final diagnostics = RideDiagnosticsController.inMemory(
      logStore: InMemoryRideDiagnosticsLogStore(),
    );
    addTearDown(diagnostics.dispose);
    await pumpHome(tester, rideDiagnostics: diagnostics);

    final map = tester.widget<HomeMapBackdrop>(find.byType(HomeMapBackdrop));
    expect(identical(map.rideDiagnostics, diagnostics), isTrue);
  });

  testWidgets('a set-aside running ride remains reachable from the top bar', (
    tester,
  ) async {
    await pumpHome(tester);
    expect(find.text('Ride with others'), findsNothing);

    // Stepping away from a running ride is the one state where Home is on
    // screen while a ride exists (#594): the app-level builder hands every
    // other live ride to the shell.
    await rideController.createRide('Oliver');
    rideController.setRunningRideAside();
    expect(rideController.rideSetAside, isTrue);
    // Pumped again rather than settled: `HomeScreen` does not listen to the
    // controller. In production the app root's `AnimatedBuilder` merges it and
    // rebuilds this screen, and pumping it afresh is that rebuild.
    await pumpHome(tester);

    final code = rideController.session!.rideCode;
    await tester.tap(find.byKey(const Key('home-more-actions')));
    await tester.pumpAndSettle();
    expect(find.text('Rejoin ride $code'), findsOneWidget);

    // And it goes back rather than merely saying so.
    await tester.tap(find.text('Rejoin ride $code'));
    await tester.pump();
    expect(rideController.rideSetAside, isFalse);
  });

  testWidgets('a saved Where To ride offers its existing export screen', (
    tester,
  ) async {
    final diagnosticsStore = InMemoryRideDiagnosticsLogStore();
    await diagnosticsStore.write(
      rideId: 'free-roam-test',
      text:
          'Tail End Charlie · ride diagnostics\n'
          'Ride:  PERSONAL\n'
          'Written: 2026-08-23T11:00:00.000Z\n\n'
          'navigation complete',
    );
    final diagnostics = RideDiagnosticsController.inMemory(
      logStore: diagnosticsStore,
    );
    addTearDown(diagnostics.dispose);
    await pumpHome(tester, rideDiagnostics: diagnostics);
    final ride = CompletedRide(
      rideId: 'free-roam-test',
      rideCode: 'PERSONAL',
      rideName: 'To Tuckers Grave',
      localDisplayName: 'Oliver',
      localRole: RideRole.rider,
      startedAt: DateTime.utc(2026, 8, 23, 10),
      endedAt: DateTime.utc(2026, 8, 23, 11),
      archivedAt: DateTime.utc(2026, 8, 23, 11),
      riderCount: 1,
      eventCount: 2,
      totalDistanceMeters: 1000,
      markerSessions: const [],
      plannedRoute: null,
      traveledRoute: null,
    );

    tester
        .widget<HomeMapBackdrop>(find.byType(HomeMapBackdrop))
        .onNavigationArchived!(ride);
    await tester.pumpAndSettle();

    expect(find.text('Navigation saved'), findsOneWidget);
    expect(find.textContaining('export the recorded GPX'), findsOneWidget);
    expect(find.byKey(const Key('open-saved-navigation')), findsOneWidget);
    expect(
      find.byKey(const Key('share-saved-navigation-diagnostics')),
      findsOneWidget,
    );
  });

  testWidgets('starting a ride is offered in words on the first screen', (
    tester,
  ) async {
    await pumpHome(tester);

    // Both changed deliberately in #595, and the rule they protect is intact:
    // every way in is still offered *in words*, which is what #306 was raised
    // over. What changed is which words.
    //
    // Group creation remains in the readable More sheet, without occupying a
    // permanent strip of map.
    expect(find.text('Ride with others'), findsNothing);
    expect(find.byKey(const Key('home-more-actions')), findsOneWidget);
    // Joining takes a six-digit code rather than a destination, so it sits
    // beside the field instead of folding into it. Shortened to fit the bar
    // next to the field; still a word, never a bare icon.
    expect(find.text('Join'), findsOneWidget);
    expect(find.text('Where to?'), findsOneWidget);
  });

  testWidgets('the compact top bar leaves Where to readable on a small phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await pumpHome(tester);

    expect(find.byTooltip('Emergency info'), findsNothing);
    expect(find.text('Where to?'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('home-search-bar'))).width,
      greaterThanOrEqualTo(132),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('ride setup uses the saved symbol and colour without repicking', (
    tester,
  ) async {
    await riderProfile.save(
      displayName: 'Oliver',
      motorcycleStyle: MotorcycleIconStyle.scrambler,
      riderSymbol: const RiderSymbol.emoji('🦊'),
      riderColor: RiderColor.cyan,
    );
    await pumpHome(tester);

    await tester.tap(find.byKey(const Key('home-more-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-create-ride')));
    await tester.pumpAndSettle();

    // The form never asks the rider to repick their identity.
    expect(find.byKey(const Key('ride-form-scroll-view')), findsOneWidget);
    expect(find.text('Your colour'), findsNothing);

    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Create ride'),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create ride'));
    await tester.pumpAndSettle();

    // And the ride carries what onboarding already knew. `createRide` defaults
    // these rather than reading the profile, so a path that forgets to pass
    // them puts the default rider on the map — which is what the old
    // destination search did.
    expect(rideController.session?.riderSymbol, const RiderSymbol.emoji('🦊'));
    expect(rideController.session?.riderColor, RiderColor.cyan);
    expect(
      rideController.session?.motorcycleStyle,
      MotorcycleIconStyle.scrambler,
    );
  });

  testWidgets('Settings is reachable by the same words with no ride (#600)', (
    tester,
  ) async {
    await pumpHome(tester);

    // A ride reaches Settings from a named list — the tab, and the same word
    // in the ride menu behind it. Free roam had only the gear, so the way to
    // Settings changed the moment a ride existed. Both are a named list now.
    await tester.tap(find.byKey(const Key('home-more-actions')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-more-settings')), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('a free-roam route does not restore the redundant bottom bar', (
    tester,
  ) async {
    await pumpHome(tester);

    // The map reports its route through `onRouteChanged` — including one
    // restored from the last session. Invoked directly because the callback
    // only fires from a live platform map, which a widget test does not have;
    // this is the same call the map makes.
    final backdrop = tester.widget<HomeMapBackdrop>(
      find.byType(HomeMapBackdrop),
    );
    backdrop.onRouteChanged!(_bathRoute());
    await tester.pumpAndSettle();

    // Navigating, with no ride in existence.
    expect(
      tester.widget<HomeMapBackdrop>(find.byType(HomeMapBackdrop)).navigating,
      isTrue,
    );
    expect(rideController.hasActiveRide, isFalse);
    expect(find.text('Ride this with others'), findsNothing);
    expect(find.text('Ride with others'), findsNothing);
  });

  testWidgets('a past ride is reachable by words alone', (tester) async {
    // Moved one tap in by #426, which removed the full-screen start panel these
    // rows used to sit on. The #306 rule is what matters and it still holds: the
    // path is words the whole way, "More" then "Ride library", with no
    // unlabelled icon anywhere on it. An overflow nobody can read would not be
    // reachable, which is why the control is a word rather than `more_horiz`.
    await pumpHome(tester);

    await tester.tap(find.byKey(const Key('home-more-actions')));
    await tester.pumpAndSettle();

    expect(find.text('Ride library'), findsOneWidget);
    expect(
      find.textContaining('Recorded routes and previous rides'),
      findsOneWidget,
    );

    await tester.tap(find.text('Ride library'));
    await tester.pumpAndSettle();
    expect(find.text('Ride library'), findsOneWidget);
    expect(find.text('No saved routes yet'), findsOneWidget);
  });

  testWidgets('the simulator and route recorder are reachable too', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.byKey(const Key('home-more-actions')));
    await tester.pumpAndSettle();

    expect(find.text('Try a simulated ride'), findsOneWidget);
    expect(find.text('Record a route'), findsOneWidget);
  });

  testWidgets('the field takes the bar while a search is open', (tester) async {
    // #595: "tapping on search expands the search box horizontally". The other
    // actions step aside so the field is the whole bar rather than one control
    // among four, and joining is offered again underneath it.
    await pumpHome(tester);
    expect(find.byKey(const Key('home-join-ride')), findsOneWidget);

    await tester.tap(find.byKey(const Key('home-search-bar')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('home-join-ride')),
      findsNothing,
      reason: 'the bar belongs to the field while a search is open',
    );
    // The way in it displaced, offered underneath the field instead.
    expect(find.byKey(const Key('home-search-join-code')), findsOneWidget);
    expect(find.text('Join a ride with a code'), findsOneWidget);
  });

  testWidgets('circular planning hands off from Where to into the map', (
    tester,
  ) async {
    await pumpHome(tester);

    tester
        .widget<HomeMapBackdrop>(find.byType(HomeMapBackdrop))
        .position!
        .value = const GeoPoint(
      latitude: 51.45,
      longitude: -2.59,
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('home-search-bar')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('home-search-circular-ride')));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<HomeMapBackdrop>(find.byType(HomeMapBackdrop))
          .circularRideRequestToken,
      isNotNull,
    );
  });

  testWidgets('joining by QR is offered in words, not only as an icon', (
    tester,
  ) async {
    // The specific failure #306 was raised over: this shipped in #279 and was
    // then concluded to be missing, because the only way to find it was an
    // unlabelled camera icon inside a text field's suffix.
    await pumpHome(tester);
    // By key rather than by label: #595 shortened the wording to fit
    // beside the search field, and what these tests are about is the sheet
    // behind it, not what the button is called.
    await tester.tap(find.byKey(const Key('home-join-ride')));
    await tester.pumpAndSettle();

    expect(
      find.text('Scan an invitation code'),
      findsOneWidget,
      reason: 'a rider who has never seen the app has to be able to read it',
    );
  });

  testWidgets('the QR icon still works for riders who have learned it', (
    tester,
  ) async {
    // Adding the label must not have quietly replaced the compact affordance.
    await pumpHome(tester);
    // By key rather than by label: #595 shortened the wording to fit
    // beside the search field, and what these tests are about is the sheet
    // behind it, not what the button is called.
    await tester.tap(find.byKey(const Key('home-join-ride')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('scan-invitation-button')), findsOneWidget);
    expect(
      find.byKey(const Key('scan-invitation-labelled-button')),
      findsOneWidget,
    );
  });
}

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async =>
      const NearbyCapabilities.unavailable();
}

class _NullRideCodeDirectory implements RideCodeDirectory {
  @override
  Future<void> register(RideSession session) async {}

  @override
  Future<RideCodeCredentials> resolve(
    String rideCode, {
    String? joinToken,
  }) async => throw const RideCodeDirectoryException('Not used in this test.');

  @override
  void close() {}
}

class _EmptyCompletedRideStore implements CompletedRideStore {
  @override
  Future<List<CompletedRide>> list() async => const [];

  @override
  Future<void> save(CompletedRide ride) async {}

  @override
  Future<void> delete(String rideId) async {}
}

ImportedRoute _bathRoute() => ImportedRoute(
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
);

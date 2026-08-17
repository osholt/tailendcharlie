import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/completed_rides_controller.dart';
import 'package:ride_relay/controllers/distance_unit_controller.dart';
import 'package:ride_relay/controllers/map_style_mode_controller.dart';
import 'package:ride_relay/controllers/ride_code_preference_controller.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/controllers/rider_profile_controller.dart';
import 'package:ride_relay/controllers/shared_route_controller.dart';
import 'package:ride_relay/controllers/speed_limit_display_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/completed_ride.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/rider_color.dart';
import 'package:ride_relay/domain/recorded_route_store.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/home/home_map_backdrop.dart';
import 'package:ride_relay/features/home/home_ride_actions.dart';
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
  });

  Future<void> pumpHome(WidgetTester tester) async {
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

  testWidgets('starting a ride is offered in words on the first screen', (
    tester,
  ) async {
    await pumpHome(tester);

    // Both changed deliberately in #595, and the rule they protect is intact:
    // every way in is still offered *in words*, which is what #306 was raised
    // over. What changed is which words.
    //
    // Going somewhere starts from the search field — the operator asked for
    // that twice — and free roam no longer creates a ride to do it (#600). The
    // bottom bar carries the one thing the field does not say: ride with other
    // people, offered as an upgrade rather than demanded as an entrance.
    expect(find.text('Ride with others'), findsOneWidget);
    // Joining takes a six-digit code rather than a destination, so it sits
    // beside the field instead of folding into it. Shortened to fit the bar
    // next to the field; still a word, never a bare icon.
    expect(find.text('Join'), findsOneWidget);
    expect(find.text('Where to?'), findsOneWidget);
  });

  testWidgets('the upgrade says the route comes with it', (tester) async {
    // A rider halfway through planning a route to Bath should not have to
    // guess whether asking for company throws it away. The bar is pumped
    // directly because the route only reaches it from a live platform map.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeRideActions(hasRoute: true, onCreate: () {}, onMore: () {}),
        ),
      ),
    );

    expect(find.text('Ride this with others'), findsOneWidget);
    expect(find.text('Ride with others'), findsNothing);
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

    // By key: the wording moves around, the rule does not. #600 turned this
    // button from "Start without a destination" — which opened the ride form —
    // into the group upgrade, which asks for nothing at all.
    await tester.tap(find.byKey(const Key('home-create-ride')));
    await tester.pumpAndSettle();

    // Nothing to fill in. There is no form to re-pick a symbol or a colour in,
    // which is the strongest form of "without repicking".
    expect(find.byKey(const Key('ride-form-scroll-view')), findsNothing);
    expect(find.text('Your colour'), findsNothing);

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

  testWidgets('a route followed in free roam comes with you (#600)', (
    tester,
  ) async {
    // Onboarding always leaves a name behind; the group upgrade asks for
    // nothing and so relies on it.
    await riderProfile.save(
      displayName: 'Oliver',
      motorcycleStyle: MotorcycleIconStyle.scrambler,
      riderSymbol: const RiderSymbol.emoji('🦊'),
      riderColor: RiderColor.cyan,
    );
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
    expect(find.text('Ride this with others'), findsOneWidget);

    await tester.tap(find.byKey(const Key('home-create-ride')));
    await tester.pumpAndSettle();

    // The ride exists now, it is a group one, and it is carrying the route the
    // rider was already following. The ride keeps its route in a store of its
    // own, so without the handoff the group would start with a blank map.
    expect(rideController.hasActiveRide, isTrue);
    expect(rideController.session?.rideName, 'Bath, Somerset');
    expect(sharedRoutes.pendingInAppRoute?.route.name, 'Bath, Somerset');
  });

  testWidgets('an upgrade that cannot be made says so', (tester) async {
    // The upgrade asks for nothing, which means nothing on screen reports a
    // refusal either — `createRide` catches its own failures into
    // `errorMessage` rather than throwing, and the ride form that used to
    // display that message is no longer on this path. A button that silently
    // does nothing is worse than the ceremony it replaced.
    await pumpHome(tester);
    tester
        .widget<HomeMapBackdrop>(find.byType(HomeMapBackdrop))
        .onRouteChanged!(_bathRoute());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-create-ride')));
    await tester.pumpAndSettle();

    expect(rideController.hasActiveRide, isFalse);
    expect(
      find.widgetWithText(SnackBar, 'Enter a rider name.'),
      findsOneWidget,
    );
    // And the route is not handed to a ride that does not exist. It would sit
    // there waiting for a shell that never mounts, and turn up on the next one.
    expect(sharedRoutes.pendingInAppRoute, isNull);
  });

  testWidgets('a past ride is reachable by words alone', (tester) async {
    // Moved one tap in by #426, which removed the full-screen start panel these
    // rows used to sit on. The #306 rule is what matters and it still holds: the
    // path is words the whole way, "More" then "Ride library", with no
    // unlabelled icon anywhere on it. An overflow nobody can read would not be
    // reachable, which is why the control is a word rather than `more_horiz`.
    await pumpHome(tester);

    expect(find.text('More'), findsOneWidget);
    await tester.tap(find.text('More'));
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
    await tester.tap(find.text('More'));
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

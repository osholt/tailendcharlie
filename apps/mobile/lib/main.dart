import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'app/ride_relay_app.dart';
import 'controllers/distance_unit_controller.dart';
import 'controllers/completed_rides_controller.dart';
import 'controllers/map_style_mode_controller.dart';
import 'controllers/ride_code_preference_controller.dart';
import 'controllers/ride_controller.dart';
import 'controllers/ride_invitation_link_controller.dart';
import 'controllers/rider_profile_controller.dart';
import 'controllers/road_rating_controller.dart';
import 'controllers/shared_route_controller.dart';
import 'controllers/speed_limit_display_controller.dart';
import 'controllers/spoken_guidance_controller.dart';
import 'controllers/test_control_controller.dart';
import 'data/json_file_recorded_route_store.dart';
import 'data/json_file_completed_ride_store.dart';
import 'data/shared_preferences_session_store.dart';
import 'data/sqlite_event_store.dart';
import 'services/nearby_bridge.dart';
import 'services/test_control_registry.dart';
import 'services/test_control_session.dart';
import 'services/test_control_server.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // maplibre_gl's compiled default is false, contrary to its own dartdoc, and
  // only takes effect if set before the first MapLibreMap is created. Without
  // it Android platform views (the full map plus the landscape mini-map) can
  // render blank or drift out of sync with Flutter's compositor; iOS has no
  // equivalent composition mode and is unaffected either way.
  MapLibreMap.useHybridComposition = true;

  // Nothing here paints until every one of these has finished, so the launch
  // sequence is exactly as slow as their sum and hangs if any one of them hangs.
  // A tester's phone came back up after a crash and stopped at a spinner (#209),
  // and a serial chain of nine disk and preference reads is the shape of startup
  // that produces that. Only the genuine dependencies stay ordered.
  final (
    (
      riderProfile,
      distanceUnits,
      mapStyleMode,
      rideCodePreference,
      sharedRoutes,
      speedLimitDisplay,
      recordedRoutes,
      // Null unless this build has a discovery catalogue endpoint compiled in, so
      // the rating card never appears where an answer could not be delivered
      // (#159).
      roadRatings,
      completedRideStore,
    ),
    // Returns immediately without touching storage in a build that has no
    // test-control define, so it costs an ordinary build nothing. Nested
    // because Dart's parallel-wait extension stops at nine futures, and this
    // must not become a tenth serial await - see the #209 note above.
    testControl,
    spokenGuidance,
    rideInvitationLinks,
  ) = await (
    (
      RiderProfileController.load(),
      DistanceUnitController.load(
        locale: WidgetsBinding.instance.platformDispatcher.locale,
      ),
      MapStyleModeController.load(),
      RideCodePreferenceController.load(),
      SharedRouteController.load(),
      SpeedLimitDisplayController.load(),
      JsonFileRecordedRouteStore.openDefault(),
      RoadRatingController.openDefault(),
      JsonFileCompletedRideStore.openDefault(),
    ).wait,
    TestControlController.load(),
    SpokenGuidanceController.load(),
    RideInvitationLinkController.load(),
  ).wait;

  final completedRides = await CompletedRidesController.load(
    completedRideStore,
  );
  final controller = RideController(
    SqliteEventStore(),
    SharedPreferencesSessionStore(),
    const NearbyBridge(),
    installationId: riderProfile.installationId,
    completedRideStore: completedRides,
  );

  // The registry is created unconditionally - it is one nullable field - but the
  // server only binds a port when the define is present and the in-app switch is
  // on. Kept here rather than inside the widget tree so the port's lifetime is
  // the process's, not a widget's.
  final testControlRegistry = TestControlRegistry();
  final testControlServer = TestControlServer(
    testControl,
    controller,
    testControlRegistry,
  );
  // Owns the port's lifetime, the screen wake lock while the surface is on, and
  // the idle clock across suspension. See TestControlSession for why the last two
  // are not optional for a multi-device run.
  TestControlSession(testControl, testControlServer).start();

  runApp(
    RideRelayApp(
      controller: controller,
      distanceUnits: distanceUnits,
      mapStyleMode: mapStyleMode,
      rideCodePreference: rideCodePreference,
      riderProfile: riderProfile,
      sharedRoutes: sharedRoutes,
      speedLimitDisplay: speedLimitDisplay,
      recordedRoutes: recordedRoutes,
      completedRides: completedRides,
      rideInvitationLinks: rideInvitationLinks,
      roadRatings: roadRatings,
      testControl: testControl,
      testControlRegistry: testControlRegistry,
      spokenGuidance: spokenGuidance,
      initializeController: controller.initialize,
    ),
  );
}

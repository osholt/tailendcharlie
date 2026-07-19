import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'app/ride_relay_app.dart';
import 'controllers/distance_unit_controller.dart';
import 'controllers/ride_controller.dart';
import 'data/shared_preferences_session_store.dart';
import 'data/sqlite_event_store.dart';
import 'services/nearby_bridge.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // maplibre_gl's compiled default is false, contrary to its own dartdoc, and
  // only takes effect if set before the first MapLibreMap is created. Without
  // it Android platform views (the full map plus the landscape mini-map) can
  // render blank or drift out of sync with Flutter's compositor; iOS has no
  // equivalent composition mode and is unaffected either way.
  MapLibreMap.useHybridComposition = true;

  final controller = RideController(
    SqliteEventStore(),
    SharedPreferencesSessionStore(),
    const NearbyBridge(),
  );
  await controller.initialize();
  final distanceUnits = await DistanceUnitController.load(
    locale: WidgetsBinding.instance.platformDispatcher.locale,
  );

  runApp(RideRelayApp(controller: controller, distanceUnits: distanceUnits));
}

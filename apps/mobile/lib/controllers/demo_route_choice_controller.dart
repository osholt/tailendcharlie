import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/demo_route_loader.dart';

/// Which bundled demo route a rider last chose, remembered between launches
/// (#934).
///
/// Read by the Ride Lab shell when it loads a simulation, and written by every
/// place that offers the choice - the home menu, Ride Lab and the map's "Load
/// demo route" - so one pick in any of them is what the next demo starts with.
class DemoRouteChoiceController extends ChangeNotifier {
  DemoRouteChoiceController._(this._preferences, this._current);

  static const preferenceKey = 'demo_route_choice_v1';

  final SharedPreferences? _preferences;
  DemoRoute _current;

  static Future<DemoRouteChoiceController> load() async {
    final preferences = await SharedPreferences.getInstance();
    return DemoRouteChoiceController._(
      preferences,
      DemoRoutes.byId(preferences.getString(preferenceKey)),
    );
  }

  factory DemoRouteChoiceController.inMemory([DemoRoute? route]) =>
      DemoRouteChoiceController._(null, route ?? DemoRoutes.fallback);

  /// The route a demo starts with now: the last choice, or the fallback.
  DemoRoute get current => _current;

  /// Remembers [route] as the one a demo starts with, even when it is the one
  /// already in use: a rider who picked the fallback on purpose should keep it
  /// if the fallback ever changes.
  Future<void> choose(DemoRoute route) async {
    final changed = _current.id != route.id;
    _current = route;
    if (changed) notifyListeners();
    await _preferences?.setString(preferenceKey, route.id);
  }
}

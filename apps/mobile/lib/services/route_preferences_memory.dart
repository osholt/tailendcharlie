import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/route_preferences.dart';

/// The route options a rider last confirmed, offered as the next plan's
/// default (#894).
///
/// Preferences still belong to the route: a confirmed route carries its own,
/// and editing it reopens those. This only decides what a *new* plan starts
/// with, so a rider who always avoids motorways does not have to say so on
/// every destination.
///
/// Storage that cannot be read or written is never a reason to fail a plan:
/// the defaults are used, and a lost memory costs one tap.
class RoutePreferencesMemory {
  const RoutePreferencesMemory();

  static const storageKey = 'ridePlan.lastRoutePreferences';

  Future<RoutePreferences> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final stored = preferences.getString(storageKey);
      if (stored == null) return RoutePreferences.defaults;
      final decoded = jsonDecode(stored);
      if (decoded is! Map) return RoutePreferences.defaults;
      return RoutePreferences.fromJson(Map<String, Object?>.from(decoded));
    } on Object {
      return RoutePreferences.defaults;
    }
  }

  Future<void> remember(RoutePreferences routePreferences) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        storageKey,
        jsonEncode(routePreferences.toJson()),
      );
    } on Object {
      // See the class comment: the next plan starts from the defaults.
    }
  }
}

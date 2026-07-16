import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'internet_cursor_store.dart';

class SharedPreferencesInternetCursorStore implements InternetCursorStore {
  static const _prefix = 'internet_relay_cursor_v1_';

  String _key(String rideId) =>
      '$_prefix${sha256.convert(utf8.encode(rideId)).toString()}';

  @override
  Future<void> clear(String rideId) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_key(rideId));
  }

  @override
  Future<String?> load(String rideId) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(_key(rideId));
  }

  @override
  Future<void> save(String rideId, String cursor) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_key(rideId), cursor);
  }
}

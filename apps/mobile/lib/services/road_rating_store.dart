import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'road_rating.dart';

/// Where road ratings live between the tap and the relay (#159).
///
/// Deliberately its own storage, not the ride journal and not the completed-ride
/// archive. A rating outlives the ride it came from: filing the ride, removing
/// it, or letting the 24-hour recovery window expire wipes ride data and must
/// not touch a rating the rider has already given. It is also why nothing in
/// here is keyed by ride: the queue records catalogue feature IDs and verdicts,
/// so there is no ride identifier left behind for a rating to be joined back to.
class RoadRatingStore {
  RoadRatingStore._(this._preferences, this._pending, this._asked);

  static const pendingKey = 'ride-relay-road-ratings-v1';
  static const askedKey = 'ride-relay-road-ratings-asked-v1';

  /// A cap on the queue, so a relay that is down for a month cannot grow it
  /// without bound. The oldest entry is dropped first.
  static const maximumPending = 50;

  /// How many roads the phone remembers having asked about. Comfortably more
  /// than a season of riding, and bounded so the record cannot grow forever.
  static const maximumAsked = 300;

  /// After this long a road becomes askable again, so a catalogue that has been
  /// republished with different geometry can be re-checked.
  static const askedRetention = Duration(days: 365);

  final SharedPreferences _preferences;
  final List<RoadRating> _pending;
  final Map<String, DateTime> _asked;

  static Future<RoadRatingStore> openDefault() async =>
      open(await SharedPreferences.getInstance());

  static Future<RoadRatingStore> open(SharedPreferences preferences) async {
    final pending = <RoadRating>[];
    try {
      final raw = jsonDecode(preferences.getString(pendingKey) ?? '[]');
      if (raw is List) {
        pending.addAll(
          raw
              .whereType<Map>()
              .map(
                (item) => RoadRating.fromJson(Map<String, Object?>.from(item)),
              )
              .take(maximumPending),
        );
      }
    } on Object {
      await preferences.remove(pendingKey);
    }
    final asked = <String, DateTime>{};
    try {
      final raw = jsonDecode(preferences.getString(askedKey) ?? '{}');
      if (raw is Map) {
        for (final entry in raw.entries) {
          final at = DateTime.tryParse(entry.value as String? ?? '');
          if (entry.key is String && at != null) {
            asked[entry.key as String] = at.toUtc();
          }
        }
      }
    } on Object {
      await preferences.remove(askedKey);
    }
    return RoadRatingStore._(preferences, pending, asked);
  }

  /// Ratings still waiting for their release time or for a working relay.
  List<RoadRating> get pending => List.unmodifiable(_pending);

  /// The roads this phone has already put to the rider - answered or skipped.
  /// One rider gets one vote per road, and a skipped road is not asked twice.
  Set<String> askedFeatureIds({required DateTime now}) => {
    for (final entry in _asked.entries)
      if (now.toUtc().difference(entry.value) < askedRetention) entry.key,
  };

  /// Records an answer: the rating joins the queue and the road is marked asked
  /// in the same write, so a crash cannot leave a road answerable twice.
  Future<void> record(RoadRating rating, {required DateTime now}) async {
    _pending.add(rating);
    while (_pending.length > maximumPending) {
      _pending.removeAt(0);
    }
    _asked[rating.featureId] = now.toUtc();
    _prune(now);
    await _save();
  }

  /// Marks a road as put to the rider without queueing anything. Used by Skip:
  /// declining is an answer to the app even though it is not one to the relay.
  Future<void> markAsked(String featureId, {required DateTime now}) async {
    _asked[featureId] = now.toUtc();
    _prune(now);
    await _save();
  }

  Future<void> remove(RoadRating rating) async {
    _pending.remove(rating);
    await _save();
  }

  void _prune(DateTime now) {
    _asked.removeWhere((_, at) => now.toUtc().difference(at) >= askedRetention);
    if (_asked.length <= maximumAsked) return;
    final ordered = _asked.entries.toList()
      ..sort((first, second) => first.value.compareTo(second.value));
    for (final entry in ordered.take(_asked.length - maximumAsked)) {
      _asked.remove(entry.key);
    }
  }

  Future<void> _save() async {
    await _preferences.setString(
      pendingKey,
      jsonEncode(_pending.map((rating) => rating.toJson()).toList()),
    );
    await _preferences.setString(
      askedKey,
      jsonEncode({
        for (final entry in _asked.entries)
          entry.key: entry.value.toIso8601String(),
      }),
    );
  }
}

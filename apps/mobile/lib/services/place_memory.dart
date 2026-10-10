/// The places a rider has been to before and the places they have named (#937).
///
/// > I would like for the search box to show a history of where I have searched
/// > before, and allow common destinations 'home', 'work' or other custom saved
/// > locations to be available too.
///
/// Two lists, one object:
///
/// - **Recent places**: somewhere the rider *chose* from a search, newest first,
///   without duplicates, capped at [PlaceMemory.recentLimit]. A search that was
///   typed and never chosen from is not a destination and is not kept.
/// - **Saved places**: Home, Work, and places the rider has named. Home and Work
///   are one each and are replaced, never duplicated.
///
/// ## Where it lives, and where it must never go
///
/// On the phone, in `SharedPreferences`, as one JSON document under
/// [PlaceMemory.preferenceKey]. **Nothing here is sent anywhere.** It is not
/// part of the ride journal, so no other rider and no relay ever sees it; it is
/// not written to the diagnostics log; it is not in a ride library backup. A
/// saved Home is the most sensitive coordinate this app could hold, which is why
/// `test/services/place_memory_privacy_test.dart` fails if any of those modules
/// ever mention this one.
///
/// ## What it does not do
///
/// It does not search. `docs/geocoder-decision.md` forbids autocomplete against
/// the public Nominatim instance, and filtering these two lists as the rider
/// types ([PlaceMemory.savedMatching], [PlaceMemory.recentsMatching]) is local
/// and needs no network. A search still happens only when it is submitted.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../domain/imported_route.dart' show GeoPoint;
import '../domain/ride_plan.dart';

/// The label a place made from the rider's own position carries. It is a
/// placeholder, not an address, so a saved place does not keep it as one.
const currentLocationPlaceLabel = 'Your location';

enum SavedPlaceKind { home, work, custom }

/// A place the rider has named.
class SavedPlace {
  const SavedPlace({
    required this.id,
    required this.kind,
    required this.name,
    required this.point,
    this.description,
  });

  static const homeId = 'home';
  static const workId = 'work';
  static const homeName = 'Home';
  static const workName = 'Work';

  final String id;
  final SavedPlaceKind kind;

  /// What the rider calls it: "Home", "Work", or their own words.
  final String name;
  final GeoPoint point;

  /// The address line it was chosen by, or null when it came from the rider's
  /// own location and has none.
  final String? description;

  /// This place as the plan surface wants it: named as the rider named it.
  RidePlanPlace toPlanPlace() =>
      RidePlanPlace(point: point, label: name, description: description);

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'name': name,
    'point': _pointJson(point),
    'description': ?description,
  };

  static SavedPlace? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = SavedPlaceKind.values.asNameMap()[json['kind']];
    final id = json['id'];
    final name = json['name'];
    final point = _pointFrom(json['point']);
    if (kind == null || id is! String || name is! String || point == null) {
      return null;
    }
    // Home and Work are known by id, so a document cannot hold two of them.
    if ((kind == SavedPlaceKind.home && id != homeId) ||
        (kind == SavedPlaceKind.work && id != workId)) {
      return null;
    }
    final description = json['description'];
    return SavedPlace(
      id: id,
      kind: kind,
      name: name,
      point: point,
      description: description is String ? description : null,
    );
  }
}

/// A place the rider chose from a search.
class RecentPlace {
  const RecentPlace({
    required this.label,
    required this.point,
    required this.usedAt,
    this.description,
  });

  /// The short name the plan shows: the first part of the address.
  final String label;
  final GeoPoint point;
  final DateTime usedAt;

  /// The full address, when it says more than [label].
  final String? description;

  RidePlanPlace toPlanPlace() =>
      RidePlanPlace(point: point, label: label, description: description);

  Map<String, Object?> toJson() => {
    'label': label,
    'point': _pointJson(point),
    'usedAt': usedAt.toUtc().toIso8601String(),
    'description': ?description,
  };

  static RecentPlace? fromJson(Object? json) {
    if (json is! Map) return null;
    final label = json['label'];
    final point = _pointFrom(json['point']);
    final usedAt = DateTime.tryParse('${json['usedAt']}');
    if (label is! String || label.trim().isEmpty || point == null) return null;
    final description = json['description'];
    return RecentPlace(
      label: label,
      point: point,
      usedAt: usedAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      description: description is String ? description : null,
    );
  }
}

/// Only where it is. A point lifted from a recorded track can carry the time it
/// was recorded and an elevation, which a place the rider chose has no use for.
Map<String, Object?> _pointJson(GeoPoint point) => {
  'latitude': point.latitude,
  'longitude': point.longitude,
};

GeoPoint? _pointFrom(Object? json) {
  if (json is! Map) return null;
  final latitude = json['latitude'];
  final longitude = json['longitude'];
  if (latitude is! num || longitude is! num) return null;
  if (!latitude.isFinite || !longitude.isFinite) return null;
  if (latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
    return null;
  }
  return GeoPoint(
    latitude: latitude.toDouble(),
    longitude: longitude.toDouble(),
  );
}

/// The two lists, and the rules that keep them tidy.
class PlaceMemory extends ChangeNotifier {
  PlaceMemory._(
    this._preferences,
    this._recents,
    this._saved,
    this._idFactory,
    this._clock,
  );

  static const preferenceKey = 'place_memory_v1';

  /// How many recent places are kept. More is a list nobody scrolls.
  static const recentLimit = 10;

  /// How many places a rider can name themselves, beyond Home and Work.
  static const customLimit = 12;

  /// The longest name a saved place can have.
  static const nameLimit = 40;

  /// Two places this close are the same place.
  static const samePlaceMeters = 30.0;

  final SharedPreferences? _preferences;
  final String Function() _idFactory;
  final DateTime Function() _clock;
  List<RecentPlace> _recents;
  List<SavedPlace> _saved;

  /// Opens what this phone holds. A document that cannot be read is treated as
  /// empty rather than failing the search it was opened for.
  static Future<PlaceMemory> open({
    String Function()? idFactory,
    DateTime Function()? clock,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final (recents, saved) = _decode(preferences.getString(preferenceKey));
    return PlaceMemory._(
      preferences,
      recents,
      saved,
      idFactory ?? () => 'custom-${const Uuid().v4()}',
      clock ?? DateTime.now,
    );
  }

  /// Holds everything in memory and writes nothing. For tests and for a surface
  /// that has no preferences to hand.
  factory PlaceMemory.inMemory({
    List<RecentPlace> recents = const [],
    List<SavedPlace> saved = const [],
    String Function()? idFactory,
    DateTime Function()? clock,
  }) {
    var next = 0;
    return PlaceMemory._(
      null,
      [...recents],
      [...saved],
      idFactory ?? () => 'custom-${next++}',
      clock ?? DateTime.now,
    );
  }

  static (List<RecentPlace>, List<SavedPlace>) _decode(String? source) {
    if (source == null) return (<RecentPlace>[], <SavedPlace>[]);
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map) return (<RecentPlace>[], <SavedPlace>[]);
      final recents = <RecentPlace>[
        for (final item in decoded['recents'] as List? ?? const [])
          ?RecentPlace.fromJson(item),
      ];
      final saved = <SavedPlace>[];
      for (final item in decoded['saved'] as List? ?? const []) {
        final place = SavedPlace.fromJson(item);
        if (place != null && !saved.any((other) => other.id == place.id)) {
          saved.add(place);
        }
      }
      return (
        recents.take(recentLimit).toList(),
        _ordered(saved).take(2 + customLimit).toList(),
      );
    } on Object {
      return (<RecentPlace>[], <SavedPlace>[]);
    }
  }

  /// Home, then Work, then the rest in the order they were added.
  static List<SavedPlace> _ordered(Iterable<SavedPlace> places) => [
    ...places.where((place) => place.kind == SavedPlaceKind.home),
    ...places.where((place) => place.kind == SavedPlaceKind.work),
    ...places.where((place) => place.kind == SavedPlaceKind.custom),
  ];

  /// Newest first.
  List<RecentPlace> get recents => List.unmodifiable(_recents);

  /// Home, Work, then the rider's own.
  List<SavedPlace> get saved => List.unmodifiable(_saved);

  SavedPlace? get home => _byId(SavedPlace.homeId);
  SavedPlace? get work => _byId(SavedPlace.workId);
  List<SavedPlace> get custom => [
    for (final place in _saved)
      if (place.kind == SavedPlaceKind.custom) place,
  ];

  SavedPlace? _byId(String id) {
    for (final place in _saved) {
      if (place.id == id) return place;
    }
    return null;
  }

  bool get isEmpty => _recents.isEmpty && _saved.isEmpty;

  // -- recents ---------------------------------------------------------------

  /// Records that the rider chose [place] from a search.
  ///
  /// A place already there - the same words, or the same spot - moves to the
  /// front instead of appearing twice, taking the newer wording.
  Future<void> remember(RidePlanPlace place, {DateTime? at}) async {
    final label = place.label.trim();
    if (label.isEmpty) return;
    final entry = RecentPlace(
      label: label,
      point: place.point,
      usedAt: at ?? _clock(),
      description: place.description,
    );
    _recents = [
      entry,
      for (final existing in _recents)
        if (!_samePlace(existing, entry)) existing,
    ].take(recentLimit).toList();
    notifyListeners();
    await _persist();
  }

  static bool _samePlace(RecentPlace first, RecentPlace second) =>
      _key(first) == _key(second) ||
      _metres(first.point, second.point) < samePlaceMeters;

  static String _key(RecentPlace place) => (place.description ?? place.label)
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  Future<void> forget(RecentPlace place) async {
    final before = _recents.length;
    _recents = [
      for (final existing in _recents)
        if (!identical(existing, place) && !_samePlace(existing, place))
          existing,
    ];
    if (_recents.length == before) return;
    notifyListeners();
    await _persist();
  }

  Future<void> clearRecents() async {
    if (_recents.isEmpty) return;
    _recents = [];
    notifyListeners();
    await _persist();
  }

  // -- saved places ----------------------------------------------------------

  /// Why [name] cannot be used, in words a rider can act on, or null when it
  /// can. [exceptId] is the place being renamed, which may keep its own name.
  String? nameProblem(String name, {String? exceptId}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Give the place a name.';
    if (trimmed.length > nameLimit) {
      return 'Keep the name to $nameLimit characters or fewer.';
    }
    final lower = trimmed.toLowerCase();
    if (lower == SavedPlace.homeName.toLowerCase() ||
        lower == SavedPlace.workName.toLowerCase()) {
      return 'Home and Work have their own places above.';
    }
    for (final place in _saved) {
      if (place.id != exceptId && place.name.toLowerCase() == lower) {
        return 'You already have a place called "${place.name}".';
      }
    }
    return null;
  }

  /// Whether another place of the rider's own can be added.
  bool get canAddCustom => custom.length < customLimit;

  /// Sets Home, replacing any earlier one.
  Future<SavedPlace> setHome(RidePlanPlace place) => _setSingle(
    id: SavedPlace.homeId,
    kind: SavedPlaceKind.home,
    name: SavedPlace.homeName,
    place: place,
  );

  /// Sets Work, replacing any earlier one.
  Future<SavedPlace> setWork(RidePlanPlace place) => _setSingle(
    id: SavedPlace.workId,
    kind: SavedPlaceKind.work,
    name: SavedPlace.workName,
    place: place,
  );

  Future<SavedPlace> _setSingle({
    required String id,
    required SavedPlaceKind kind,
    required String name,
    required RidePlanPlace place,
  }) async {
    final saved = SavedPlace(
      id: id,
      kind: kind,
      name: name,
      point: place.point,
      description: _addressOf(place),
    );
    _saved = _ordered([
      for (final existing in _saved)
        if (existing.id != id) existing,
      saved,
    ]);
    notifyListeners();
    await _persist();
    return saved;
  }

  /// Adds a place the rider names. Returns null, changing nothing, when the
  /// name will not do or the rider already has [customLimit] of them.
  Future<SavedPlace?> addCustom(String name, RidePlanPlace place) async {
    if (nameProblem(name) != null || !canAddCustom) return null;
    final saved = SavedPlace(
      id: _idFactory(),
      kind: SavedPlaceKind.custom,
      name: name.trim(),
      point: place.point,
      description: _addressOf(place),
    );
    _saved = _ordered([..._saved, saved]);
    notifyListeners();
    await _persist();
    return saved;
  }

  /// Renames one of the rider's own places. Home and Work keep their names.
  /// Returns false, changing nothing, when the name will not do.
  Future<bool> rename(String id, String name) async {
    final place = _byId(id);
    if (place == null || place.kind != SavedPlaceKind.custom) return false;
    if (nameProblem(name, exceptId: id) != null) return false;
    _replace(
      SavedPlace(
        id: place.id,
        kind: place.kind,
        name: name.trim(),
        point: place.point,
        description: place.description,
      ),
    );
    notifyListeners();
    await _persist();
    return true;
  }

  /// Moves a saved place somewhere else, keeping its name.
  Future<bool> relocate(String id, RidePlanPlace place) async {
    final existing = _byId(id);
    if (existing == null) return false;
    _replace(
      SavedPlace(
        id: existing.id,
        kind: existing.kind,
        name: existing.name,
        point: place.point,
        description: _addressOf(place),
      ),
    );
    notifyListeners();
    await _persist();
    return true;
  }

  Future<void> delete(String id) async {
    final before = _saved.length;
    _saved = [
      for (final place in _saved)
        if (place.id != id) place,
    ];
    if (_saved.length == before) return;
    notifyListeners();
    await _persist();
  }

  void _replace(SavedPlace replacement) {
    _saved = [
      for (final place in _saved)
        if (place.id == replacement.id) replacement else place,
    ];
  }

  /// The address a saved place keeps: the full description when there is one,
  /// and otherwise the label, unless that is only a placeholder: the one a
  /// dropped pin carries or the one the rider's own location does.
  static String? _addressOf(RidePlanPlace place) {
    final description = place.description?.trim();
    if (description != null && description.isNotEmpty) return description;
    final label = place.label.trim();
    return label.isEmpty ||
            label == RidePlanPlace.droppedPinLabel ||
            label == currentLocationPlaceLabel
        ? null
        : label;
  }

  // -- filtering as the rider types ------------------------------------------

  /// The saved places [query] could be the start of: every word of it appears
  /// somewhere in the name or address, in any case. An empty query is all of
  /// them. Local and instant; nothing is sent anywhere.
  List<SavedPlace> savedMatching(String query) => [
    for (final place in _saved)
      if (_matches(query, [place.name, place.description])) place,
  ];

  /// As [savedMatching], for the recent places.
  List<RecentPlace> recentsMatching(String query) => [
    for (final place in _recents)
      if (_matches(query, [place.label, place.description])) place,
  ];

  static bool _matches(String query, List<String?> fields) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty);
    if (words.isEmpty) return true;
    final haystack = fields.whereType<String>().join(' ').toLowerCase();
    return words.every(haystack.contains);
  }

  // -- storage ---------------------------------------------------------------

  Future<void> _persist() async {
    final preferences = _preferences;
    if (preferences == null) return;
    if (_recents.isEmpty && _saved.isEmpty) {
      await preferences.remove(preferenceKey);
      return;
    }
    await preferences.setString(
      preferenceKey,
      jsonEncode({
        'v': 1,
        'recents': [for (final place in _recents) place.toJson()],
        'saved': [for (final place in _saved) place.toJson()],
      }),
    );
  }
}

double _metres(GeoPoint first, GeoPoint second) {
  const earthRadius = 6371000.0;
  final lat1 = first.latitude * math.pi / 180;
  final lat2 = second.latitude * math.pi / 180;
  final dLat = lat2 - lat1;
  final dLon = (second.longitude - first.longitude) * math.pi / 180;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * earthRadius * math.asin(math.min(1, math.sqrt(a)));
}

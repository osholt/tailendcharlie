import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/completed_ride.dart';
import '../domain/imported_route.dart';
import '../services/global_ride_heatmap.dart';

class BulkHeatmapContributionResult {
  const BulkHeatmapContributionResult({
    required this.rideCount,
    required this.cellCount,
  });

  final int rideCount;
  final int cellCount;

  bool get shared => rideCount > 0 && cellCount > 0;
}

class GlobalRideHeatmapController extends ChangeNotifier {
  GlobalRideHeatmapController._(
    this._preferences,
    this._credentials,
    this._client,
    this._visible,
    this._consent,
    this._trimMeters,
    this._snapshot,
  );

  static const visibleKey = 'global_ride_heatmap_visible';
  static const consentKey = 'global_ride_heatmap_consent';
  static const trimKey = 'global_ride_heatmap_trim_meters';
  static const cacheKey = 'global_ride_heatmap_cache_v1';
  static const contributedRideIdsKey =
      'global_ride_heatmap_contributed_rides_v1';

  final SharedPreferences _preferences;
  final HeatmapCredentialStore _credentials;
  final GlobalHeatmapClient _client;
  bool _visible;
  HeatmapContributionConsent _consent;
  int _trimMeters;
  GlobalHeatmapSnapshot _snapshot;
  GlobalHeatmapStatus _status = GlobalHeatmapStatus.idle;
  bool _sharingHistory = false;
  int _requestGeneration = 0;

  static Future<GlobalRideHeatmapController> load({
    required GlobalHeatmapClient client,
    HeatmapCredentialStore credentials = const SecureHeatmapCredentialStore(),
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final consent =
        HeatmapContributionConsent.values
            .where((value) => value.name == preferences.getString(consentKey))
            .firstOrNull ??
        HeatmapContributionConsent.always;
    final rawCache = preferences.getString(cacheKey);
    var snapshot = GlobalHeatmapSnapshot.empty;
    if (rawCache != null) {
      try {
        snapshot = GlobalHeatmapSnapshot.fromJson(
          Map<String, Object?>.from(jsonDecode(rawCache) as Map),
        );
      } on Object {
        await preferences.remove(cacheKey);
      }
    }
    return GlobalRideHeatmapController._(
      preferences,
      credentials,
      client,
      preferences.getBool(visibleKey) ?? false,
      consent,
      preferences.getInt(trimKey) ?? 1000,
      snapshot,
    );
  }

  bool get visible => _visible;
  HeatmapContributionConsent get consent => _consent;
  int get trimMeters => _trimMeters;
  GlobalHeatmapSnapshot get snapshot => _snapshot;
  GlobalHeatmapStatus get status => _status;
  bool get sharingHistory => _sharingHistory;

  Future<void> setVisible(bool value) async {
    if (_visible == value) return;
    _visible = value;
    await _preferences.setBool(visibleKey, value);
    notifyListeners();
  }

  Future<void> setConsent(HeatmapContributionConsent value) async {
    if (_consent == value) return;
    _consent = value;
    await _preferences.setString(consentKey, value.name);
    notifyListeners();
  }

  Future<void> setTrimMeters(int value) async {
    if (![0, 500, 1000, 2000].contains(value)) {
      throw ArgumentError.value(value, 'value');
    }
    _trimMeters = value;
    await _preferences.setInt(trimKey, value);
    notifyListeners();
  }

  Future<void> refresh({
    required double west,
    required double south,
    required double east,
    required double north,
    required int zoom,
  }) async {
    final generation = ++_requestGeneration;
    _status = GlobalHeatmapStatus.loading;
    notifyListeners();
    try {
      final result = await _client.fetch(
        west: west,
        south: south,
        east: east,
        north: north,
        zoom: zoom,
      );
      if (generation != _requestGeneration) return;
      _snapshot = result;
      _status = result.cells.isEmpty
          ? GlobalHeatmapStatus.empty
          : GlobalHeatmapStatus.ready;
      await _preferences.setString(
        cacheKey,
        jsonEncode({
          'type': 'FeatureCollection',
          'snapshotVersion': result.version,
          'snapshotDate': result.date,
          'features': result.toGeoJson()['features'],
        }),
      );
    } on Object {
      if (generation != _requestGeneration) return;
      _status = _snapshot.cells.isEmpty
          ? GlobalHeatmapStatus.failed
          : GlobalHeatmapStatus.offline;
    } finally {
      if (generation == _requestGeneration) notifyListeners();
    }
  }

  Future<bool> contribute(CompletedRide ride) async {
    if (_consent == HeatmapContributionConsent.never) return false;
    final contributed =
        _preferences.getStringList(contributedRideIdsKey) ?? const [];
    if (contributed.contains(ride.rideId)) return true;
    final contribution = const HeatmapContributionBuilder().build(
      ride,
      trimMeters: _trimMeters,
    );
    if (contribution.isEmpty) return false;
    final credential = await _credential();
    await _client.contribute(credential, contribution);
    await _preferences.setStringList(
      contributedRideIdsKey,
      {...contributed, ride.rideId}.toList(growable: false),
    );
    return true;
  }

  Future<BulkHeatmapContributionResult> contributeHistory(
    Iterable<CompletedRide> rides,
  ) async {
    if (_consent == HeatmapContributionConsent.never || _sharingHistory) {
      return const BulkHeatmapContributionResult(rideCount: 0, cellCount: 0);
    }
    _sharingHistory = true;
    notifyListeners();
    try {
      final contributed =
          _preferences.getStringList(contributedRideIdsKey) ?? const [];
      final eligible = rides
          .where((ride) => !contributed.contains(ride.rideId))
          .where(_hasTravelledTrack)
          .toList(growable: false);
      if (eligible.isEmpty) {
        return const BulkHeatmapContributionResult(rideCount: 0, cellCount: 0);
      }
      final contribution = const HeatmapContributionBuilder().buildMany(
        eligible,
        trimMeters: _trimMeters,
      );
      if (contribution.isEmpty) {
        return const BulkHeatmapContributionResult(rideCount: 0, cellCount: 0);
      }
      final credential = await _credential();
      await _client.contribute(credential, contribution);
      await _preferences.setStringList(contributedRideIdsKey, [
        ...contributed,
        ...eligible.map((ride) => ride.rideId),
      ]);
      return BulkHeatmapContributionResult(
        rideCount: eligible.length,
        cellCount: contribution.cells.length,
      );
    } finally {
      _sharingHistory = false;
      notifyListeners();
    }
  }

  Future<HeatmapCredential> _credential() async {
    var credential = await _credentials.read();
    if (credential != null) return credential;
    credential = HeatmapCredential.generate();
    await _client.register(credential);
    await _credentials.write(credential);
    return credential;
  }

  static bool _hasTravelledTrack(CompletedRide ride) =>
      ride.libraryStatus != RideLibraryStatus.deleted &&
      (ride.traveledRoute?.paths.any(
            (path) =>
                path.kind == RoutePathKind.track && path.points.length >= 2,
          ) ??
          false);

  Future<void> stopAndRemoveContributions() async {
    final credential = await _credentials.read();
    if (credential != null) await _client.revoke(credential);
    await _credentials.delete();
    await _preferences.remove(contributedRideIdsKey);
    await setConsent(HeatmapContributionConsent.never);
  }

  @override
  void dispose() {
    _requestGeneration += 1;
    super.dispose();
  }
}

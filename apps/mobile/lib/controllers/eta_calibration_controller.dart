import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/completed_ride.dart';
import '../domain/imported_route.dart';
import '../services/eta_calibration.dart';
import '../services/eta_population_client.dart';
import 'completed_rides_controller.dart';

EtaCalibration _calculate((List<CompletedRide>, DateTime?) input) =>
    EtaCalibration.fromRides(input.$1, since: input.$2);

class EtaCalibrationController extends ChangeNotifier {
  EtaCalibrationController._(this._rides, this._preferences, this._client) {
    _rides.addListener(_scheduleRefresh);
  }
  final CompletedRidesController _rides;
  final SharedPreferences _preferences;
  final EtaPopulationClient _client;
  EtaCalibration _calibration = EtaCalibration.empty;
  Map<String, double> _population = {};
  Timer? _debounce;
  Future<void> _remoteChain = Future.value();
  int _generation = 0;
  bool _disposed = false;
  String? syncMessage;
  static const enabledKey = 'personal_eta_enabled';
  static const shareKey = 'anonymous_eta_opt_in_v1';
  static const removalKey = 'anonymous_eta_removal_pending';
  static const resetKey = 'personal_eta_reset_after';
  static const cacheKey = 'eta_population_cache_v1';
  static const cacheDateKey = 'eta_population_cache_date_v1';

  static Future<EtaCalibrationController> load({
    required CompletedRidesController rides,
    required EtaPopulationClient client,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final result = EtaCalibrationController._(rides, preferences, client);
    try {
      final date = DateTime.tryParse(preferences.getString(cacheDateKey) ?? '');
      if (date != null && DateTime.now().difference(date).inDays < 7) {
        final cache =
            jsonDecode(preferences.getString(cacheKey) ?? '{}') as Map;
        result._population = {
          for (final band in ['urban', 'mixed', 'open'])
            if (cache[band] case final num factor
                when factor >= .85 && factor <= 1.15)
              band: factor.toDouble(),
        };
      }
    } on Object {
      /* Corrupt cache cannot affect navigation. */
    }
    return result;
  }

  bool get enabled => _preferences.getBool(enabledKey) ?? true;
  bool get contributing => _preferences.getBool(shareKey) ?? false;
  bool get removalPending => _preferences.getBool(removalKey) ?? false;
  int get sampleCount => _calibration.sampleCount;
  bool get _populationFresh {
    final date = DateTime.tryParse(_preferences.getString(cacheDateKey) ?? '');
    return date != null && DateTime.now().difference(date).inDays < 7;
  }

  bool get hasPopulation => _populationFresh && _population.isNotEmpty;

  double factorFor(ImportedRoute route) {
    final prior = _populationFresh ? _population[etaBand(route)] ?? 1 : 1.0;
    return enabled
        ? _calibration.factorFor(route, populationFactor: prior)
        : prior;
  }

  Future<void> setEnabled(bool value) async {
    await _preferences.setBool(enabledKey, value);
    _notify();
  }

  Future<void> reset() async {
    await _preferences.setString(
      resetKey,
      DateTime.now().toUtc().toIso8601String(),
    );
    await refresh();
  }

  Future<void> setContributing(bool value) async {
    await _preferences.setBool(shareKey, value);
    if (!value) await _preferences.setBool(removalKey, true);
    _notify();
    await sync();
  }

  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), () => unawaited(refresh()));
  }

  Future<void> refresh() async {
    final generation = ++_generation;
    final since = DateTime.tryParse(_preferences.getString(resetKey) ?? '');
    final calibration = await compute(_calculate, (_rides.allRides, since));
    if (_disposed || generation != _generation) return;
    _calibration = calibration;
    _notify();
    await sync();
  }

  Future<void> sync({bool force = false}) {
    _remoteChain = _remoteChain.then((_) => _sync(force: force));
    return _remoteChain;
  }

  Future<void> _sync({required bool force}) async {
    if (_disposed) return;
    try {
      // Serialized after any in-flight upload. Opt-out survives restarts and
      // never loses the deletion credential while offline.
      if (removalPending) {
        await _client.revoke();
        await _preferences.setBool(removalKey, false);
        await _preferences.remove('eta_last_shared_profile');
      }
      if (contributing && !removalPending) {
        final profile = _calibration.anonymousProfile;
        final signature = jsonEncode(profile);
        final lastShared = DateTime.tryParse(
          _preferences.getString('eta_last_shared_date') ?? '',
        );
        if (_preferences.getString('eta_last_shared_profile') != signature ||
            lastShared == null ||
            DateTime.now().difference(lastShared).inDays >= 30) {
          await _client.replace(profile);
          await _preferences.setString('eta_last_shared_profile', signature);
          await _preferences.setString(
            'eta_last_shared_date',
            DateTime.now().toUtc().toIso8601String(),
          );
        }
      }
      final lastFetch = DateTime.tryParse(
        _preferences.getString(cacheDateKey) ?? '',
      );
      if (force ||
          lastFetch == null ||
          DateTime.now().difference(lastFetch).inHours >= 24) {
        _population = await _client.fetch();
        await _preferences.setString(cacheKey, jsonEncode(_population));
        await _preferences.setString(
          cacheDateKey,
          DateTime.now().toUtc().toIso8601String(),
        );
      }
      syncMessage = null;
    } on Object {
      syncMessage = removalPending
          ? 'Sharing is off. Removal will retry when connected.'
          : 'Motorcycle trends unavailable. Saved estimates still work.';
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _rides.removeListener(_scheduleRefresh);
    _client.close();
    super.dispose();
  }
}

class EtaCalibrationScope extends InheritedNotifier<EtaCalibrationController> {
  const EtaCalibrationScope({
    super.key,
    required EtaCalibrationController controller,
    required super.child,
  }) : super(notifier: controller);
  static EtaCalibrationController? read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<EtaCalibrationScope>()?.notifier;
  static EtaCalibrationController? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<EtaCalibrationScope>()
      ?.notifier;
}

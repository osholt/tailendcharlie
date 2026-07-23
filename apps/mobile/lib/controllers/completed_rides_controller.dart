import 'package:flutter/foundation.dart';

import '../domain/completed_ride.dart';
import '../domain/completed_ride_store.dart';

class CompletedRidesController extends ChangeNotifier
    implements CompletedRideStore {
  CompletedRidesController._(this._store, this._rides);

  final CompletedRideStore _store;
  List<CompletedRide> _rides;

  List<CompletedRide> get rides => List.unmodifiable(_rides);

  static Future<CompletedRidesController> load(
    CompletedRideStore store,
  ) async => CompletedRidesController._(store, await store.list());

  @override
  Future<List<CompletedRide>> list() async => List.unmodifiable(_rides);

  @override
  Future<void> save(CompletedRide ride) async {
    await _store.save(ride);
    _rides = [
      ride,
      ..._rides.where((existing) => existing.rideId != ride.rideId),
    ]..sort((left, right) => right.endedAt.compareTo(left.endedAt));
    notifyListeners();
  }

  @override
  Future<void> delete(String rideId) async {
    await _store.delete(rideId);
    _rides = _rides
        .where((existing) => existing.rideId != rideId)
        .toList(growable: false);
    notifyListeners();
  }
}

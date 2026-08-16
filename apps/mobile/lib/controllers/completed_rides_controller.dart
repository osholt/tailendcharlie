import 'package:flutter/foundation.dart';

import '../domain/completed_ride.dart';
import '../domain/completed_ride_store.dart';

class CompletedRidesController extends ChangeNotifier
    implements CompletedRideStore {
  CompletedRidesController._(this._store, this._rides);

  final CompletedRideStore _store;
  List<CompletedRide> _rides;

  List<CompletedRide> get rides => List.unmodifiable(
    _rides.where((ride) => ride.libraryStatus == RideLibraryStatus.active),
  );

  List<CompletedRide> get archivedRides => List.unmodifiable(
    _rides.where((ride) => ride.libraryStatus == RideLibraryStatus.archived),
  );

  List<CompletedRide> get deletedRides => List.unmodifiable(
    _rides.where((ride) => ride.libraryStatus == RideLibraryStatus.deleted),
  );

  List<CompletedRide> get allRides => List.unmodifiable(_rides);

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

  Future<void> rename(String rideId, String? name) => _update(
    rideId,
    (ride) => ride.copyWith(
      libraryName: name?.trim(),
      clearLibraryName: name?.trim().isEmpty ?? true,
    ),
  );

  Future<void> rate(String rideId, int? rating) {
    if (rating != null && (rating < 1 || rating > 5)) {
      throw RangeError.range(rating, 1, 5, 'rating');
    }
    return _update(
      rideId,
      (ride) => ride.copyWith(rating: rating, clearRating: rating == null),
    );
  }

  Future<void> setNotes(String rideId, String? notes) => _update(
    rideId,
    (ride) => ride.copyWith(
      notes: notes?.trim(),
      clearNotes: notes?.trim().isEmpty ?? true,
    ),
  );

  Future<void> archive(String rideId) => _update(
    rideId,
    (ride) => ride.copyWith(
      libraryStatus: RideLibraryStatus.archived,
      clearDeletedAt: true,
    ),
  );

  Future<void> moveToTrash(String rideId, {DateTime? deletedAt}) => _update(
    rideId,
    (ride) => ride.copyWith(
      libraryStatus: RideLibraryStatus.deleted,
      deletedAt: deletedAt ?? DateTime.now().toUtc(),
    ),
  );

  Future<void> restore(String rideId) => _update(
    rideId,
    (ride) => ride.copyWith(
      libraryStatus: RideLibraryStatus.active,
      clearDeletedAt: true,
    ),
  );

  Future<void> _update(
    String rideId,
    CompletedRide Function(CompletedRide ride) update,
  ) async {
    final index = _rides.indexWhere((ride) => ride.rideId == rideId);
    if (index < 0) return;
    await save(update(_rides[index]));
  }
}

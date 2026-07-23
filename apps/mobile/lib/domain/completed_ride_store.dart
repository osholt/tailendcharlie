import 'completed_ride.dart';

abstract interface class CompletedRideStore {
  Future<List<CompletedRide>> list();

  Future<void> save(CompletedRide ride);

  Future<void> delete(String rideId);
}

class InMemoryCompletedRideStore implements CompletedRideStore {
  final Map<String, CompletedRide> _rides = {};

  @override
  Future<List<CompletedRide>> list() async =>
      _rides.values.toList()
        ..sort((left, right) => right.endedAt.compareTo(left.endedAt));

  @override
  Future<void> save(CompletedRide ride) async => _rides[ride.rideId] = ride;

  @override
  Future<void> delete(String rideId) async => _rides.remove(rideId);
}

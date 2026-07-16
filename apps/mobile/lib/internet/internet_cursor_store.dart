abstract interface class InternetCursorStore {
  Future<String?> load(String rideId);

  Future<void> save(String rideId, String cursor);

  Future<void> clear(String rideId);
}

class InMemoryInternetCursorStore implements InternetCursorStore {
  final Map<String, String> _cursors = {};

  @override
  Future<void> clear(String rideId) async => _cursors.remove(rideId);

  @override
  Future<String?> load(String rideId) async => _cursors[rideId];

  @override
  Future<void> save(String rideId, String cursor) async {
    _cursors[rideId] = cursor;
  }
}

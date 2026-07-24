import '../internet/observer_access_client.dart';

abstract interface class ObserverGrantStore {
  Future<List<ObserverGrantCredentials>> load(String rideId);

  Future<void> save(String rideId, List<ObserverGrantCredentials> credentials);

  Future<void> delete(String rideId);

  Future<ObserverLocalAssistanceState?> loadLocalAssistance(String rideId);

  Future<void> saveLocalAssistance(
    String rideId,
    ObserverLocalAssistanceState state,
  );

  Future<void> deleteLocalAssistance(String rideId);
}

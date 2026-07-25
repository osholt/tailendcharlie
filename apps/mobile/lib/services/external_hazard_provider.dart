import '../domain/geo_point.dart';
import '../domain/hazard.dart';

enum ExternalHazardProviderState {
  unavailable,
  needsConfiguration,
  configured,
  loading,
  ready,
  failed,
}

class ExternalHazardProviderStatus {
  const ExternalHazardProviderStatus({
    required this.state,
    required this.message,
    this.lastUpdatedAt,
  });

  final ExternalHazardProviderState state;
  final String message;
  final DateTime? lastUpdatedAt;

  bool get canFetch =>
      state == ExternalHazardProviderState.configured ||
      state == ExternalHazardProviderState.ready ||
      state == ExternalHazardProviderState.failed;
}

class ExternalHazardQuery {
  const ExternalHazardQuery({
    required this.rideId,
    required this.route,
    required this.requestedAt,
    this.corridorMeters = 1000,
  });

  final String rideId;
  final List<GeoPoint> route;
  final DateTime requestedAt;
  final double corridorMeters;
}

class ExternalHazardFetchResult {
  const ExternalHazardFetchResult({
    required this.status,
    this.hazards = const [],
  });

  final ExternalHazardProviderStatus status;
  final List<HazardReport> hazards;
}

abstract interface class ExternalHazardProvider {
  String get id;

  String get displayName;

  ExternalHazardProviderStatus get status;

  Future<ExternalHazardFetchResult> fetch(ExternalHazardQuery query);
}

class UnavailableExternalHazardProvider implements ExternalHazardProvider {
  const UnavailableExternalHazardProvider({
    required this.id,
    required this.displayName,
    required this.reason,
  });

  @override
  final String id;

  @override
  final String displayName;

  final String reason;

  @override
  ExternalHazardProviderStatus get status => ExternalHazardProviderStatus(
    state: ExternalHazardProviderState.unavailable,
    message: reason,
  );

  @override
  Future<ExternalHazardFetchResult> fetch(ExternalHazardQuery query) async =>
      ExternalHazardFetchResult(status: status);
}

class UnconfiguredExternalHazardProvider implements ExternalHazardProvider {
  const UnconfiguredExternalHazardProvider({
    required this.id,
    required this.displayName,
    required this.configurationHint,
  });

  @override
  final String id;

  @override
  final String displayName;

  final String configurationHint;

  @override
  ExternalHazardProviderStatus get status => ExternalHazardProviderStatus(
    state: ExternalHazardProviderState.needsConfiguration,
    message: configurationHint,
  );

  @override
  Future<ExternalHazardFetchResult> fetch(ExternalHazardQuery query) async =>
      ExternalHazardFetchResult(status: status);
}

/// Explicit placeholder for direct Waze access from the app.
///
/// Waze exposes no client-side read API for its crowd reports. Where a Waze
/// for Cities partner feed is available it is read by the relay, which holds
/// the credential and serves the result through the live traffic provider, so
/// the app never talks to Waze itself.
class WazeReadHazardProvider extends UnavailableExternalHazardProvider {
  const WazeReadHazardProvider()
    : super(
        id: 'waze-read',
        displayName: 'Waze reports',
        reason:
            'Waze reports reach this app only through the relay traffic '
            'feed, never by direct app access.',
      );
}

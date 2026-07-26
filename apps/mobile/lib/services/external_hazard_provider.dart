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

/// Explicit placeholder for Waze read data.
///
/// Waze exposes no client-side read API for its crowd reports, and the partner
/// programme that does return a feed is limited to government agencies and road
/// operators. Tail End Charlie applied and is not eligible, so there is no
/// lawful route to this data and the provider stays permanently unavailable
/// rather than pretending to be unconfigured.
class WazeReadHazardProvider extends UnavailableExternalHazardProvider {
  const WazeReadHazardProvider()
    : super(
        id: 'waze-read',
        displayName: 'Waze reports',
        reason:
            'Tail End Charlie is not eligible for the Waze partner feed, and '
            'Waze has no other read API.',
      );
}

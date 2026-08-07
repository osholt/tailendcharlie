import '../domain/hazard.dart';
import 'external_hazard_provider.dart';
import 'fixed_speed_camera_catalogue.dart';

/// Feeds the bundled fixed-camera layer into the warning the app already has.
///
/// The rider asked why fixed cameras never appeared. The warning surface was
/// never the missing piece - `EnforcementAlertDetector` has always raised one a
/// mile out and cleared it once passed - it simply had nothing but rider
/// sightings to work from. This provides the other source, through the same
/// interface a commercial feed would use.
class FixedSpeedCameraProvider implements ExternalHazardProvider {
  /// Reads the catalogue on first fetch rather than at construction.
  ///
  /// Setting a ride up must not wait on a file. Awaiting the asset while the
  /// awareness controller was being built stalled the frame loop long enough
  /// that `pumpAndSettle` never completed, and on a phone it would be a read of
  /// thousands of coordinates on the way into a ride. [fetch] already runs off
  /// the frame path, so the cost belongs there.
  FixedSpeedCameraProvider({
    required this._readCatalogue,
    this.corridorMeters = 250,
  });

  /// A provider over an already-loaded catalogue, for tests and for a caller
  /// that has one to hand.
  FixedSpeedCameraProvider.ready(
    FixedSpeedCameraCatalogue catalogue, {
    this.corridorMeters = 250,
  }) : _readCatalogue = (() async => catalogue),
       _catalogue = catalogue;

  /// The provider credited on every camera it produces. Riders' own sightings
  /// keep [HazardSource.rider], so the two never blur together.
  static const providerId = osmFixedCameraProviderId;

  /// How long a produced camera stays live.
  ///
  /// It is not an expiry in the sense a rider report has one - a fixed camera
  /// does not go away - only long enough that it cannot lapse mid-ride. The
  /// catalogue re-asserts every camera at the next fetch, so this is a backstop
  /// against a stale event outliving the extract it came from, not a lifetime.
  static const catalogueLifetime = Duration(days: 30);

  final Future<FixedSpeedCameraCatalogue> Function() _readCatalogue;

  /// Matches the detector's own route corridor, so every camera drawn is one
  /// that can actually raise a warning.
  final double corridorMeters;

  FixedSpeedCameraCatalogue? _catalogue;

  @override
  String get id => providerId;

  @override
  String get displayName => 'Fixed cameras (OpenStreetMap)';

  @override
  ExternalHazardProviderStatus get status {
    final catalogue = _catalogue;
    if (catalogue == null) {
      return const ExternalHazardProviderStatus(
        // Not read yet, so nothing is known either way. `configured` keeps
        // [ExternalHazardProviderStatus.canFetch] true, which is what lets the
        // first fetch happen and load it.
        state: ExternalHazardProviderState.configured,
        message: 'Reading the bundled camera layer.',
      );
    }
    if (catalogue.isEmpty) {
      return const ExternalHazardProviderStatus(
        state: ExternalHazardProviderState.unavailable,
        // Never phrased as "no cameras". An empty layer means the app has
        // nothing to say about this road, which is not the same claim.
        message: 'No camera data is bundled with this build.',
      );
    }
    return ExternalHazardProviderStatus(
      state: ExternalHazardProviderState.ready,
      message:
          '${catalogue.cameras.length} fixed cameras · '
          '${catalogue.boundedRegion} · '
          'OpenStreetMap extract ${catalogue.extractDate}. '
          'OpenStreetMap does not list every camera, so this cannot tell you a '
          'road is clear.',
    );
  }

  @override
  Future<ExternalHazardFetchResult> fetch(ExternalHazardQuery query) async {
    final catalogue = _catalogue ??= await _readCatalogue();
    if (catalogue.isEmpty) {
      return ExternalHazardFetchResult(status: status);
    }
    final found = catalogue.near(query.route, corridorMeters: corridorMeters);
    return ExternalHazardFetchResult(
      status: status,
      hazards: [
        for (final camera in found)
          HazardReport(
            // Derived from the OpenStreetMap node, so two riders reaching the
            // same camera raise the same id and it merges instead of doubling.
            id: 'osm-camera-${camera.osmId.replaceAll('/', '-')}',
            rideId: query.rideId,
            type: HazardType.speedCamera,
            // Deliberately not `serious`. A permanent camera on a road the
            // group chose is worth knowing about and worth slowing for, but it
            // is not an emergency, and it must not read as urgently as a rider
            // calling out a patrol car that is actually there right now.
            severity: HazardSeverity.caution,
            position: camera.position,
            reportedAt: query.requestedAt,
            updatedAt: query.requestedAt,
            expiresAt: query.requestedAt.add(catalogueLifetime),
            reporterId: providerId,
            reporterName: displayName,
            source: HazardSource.externalProvider,
            providerId: providerId,
            details: camera.description,
          ),
      ],
    );
  }
}

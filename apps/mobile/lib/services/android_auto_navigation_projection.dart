import '../domain/distance_unit.dart';
import '../domain/imported_route.dart';
import 'guidance_time_remaining.dart';
import 'navigation_guidance.dart';
import 'route_journey_progress.dart';
import 'route_progress.dart';

enum AndroidAutoNavigationHostEventType {
  started,
  stopped,
  externalDestination,
  autoDriveEnabled,
  rerouteRequested,
  arrived,
  restorationAcknowledged,
}

/// A bounded event sent from the Android Auto host back to the Dart owner.
class AndroidAutoNavigationHostEvent {
  const AndroidAutoNavigationHostEvent({
    required this.type,
    this.navigationSessionId,
    this.routeId,
    this.destination,
    this.reason,
    this.projectionSequence,
  });

  final AndroidAutoNavigationHostEventType type;
  final String? navigationSessionId;
  final String? routeId;
  final GeoPoint? destination;
  final String? reason;
  final int? projectionSequence;

  static AndroidAutoNavigationHostEvent? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final rawType = raw['type'];
    final type = rawType is String
        ? AndroidAutoNavigationHostEventType.values
              .where((candidate) => candidate.name == rawType)
              .firstOrNull
        : null;
    if (type == null) return null;
    final navigationSessionId = _boundedOptionalString(
      raw['navigationSessionId'],
      200,
    );
    final routeId = _boundedOptionalString(raw['routeId'], 160);
    final reason = _boundedOptionalString(raw['reason'], 160);
    if ((raw['navigationSessionId'] != null && navigationSessionId == null) ||
        (raw['routeId'] != null && routeId == null) ||
        (raw['reason'] != null && reason == null)) {
      return null;
    }
    final sequence = raw['projectionSequence'];
    if (sequence != null && (sequence is! int || sequence < 1)) return null;
    final destination = _point(raw['destination']);
    if (raw['destination'] != null && destination == null) return null;
    return AndroidAutoNavigationHostEvent(
      type: type,
      navigationSessionId: navigationSessionId,
      routeId: routeId,
      destination: destination,
      reason: reason,
      projectionSequence: sequence as int?,
    );
  }

  static String? _boundedOptionalString(Object? raw, int maximumLength) {
    if (raw == null) return null;
    if (raw is! String) return null;
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    return trimmed.length <= maximumLength
        ? trimmed
        : trimmed.substring(0, maximumLength);
  }

  static GeoPoint? _point(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) return null;
    final latitude = raw['latitude'];
    final longitude = raw['longitude'];
    if (latitude is! num || longitude is! num) return null;
    final lat = latitude.toDouble();
    final lon = longitude.toDouble();
    if (!lat.isFinite ||
        !lon.isFinite ||
        lat < -90 ||
        lat > 90 ||
        lon < -180 ||
        lon > 180) {
      return null;
    }
    return GeoPoint(latitude: lat, longitude: lon);
  }
}

/// Versioned navigation state intended only for the native Android Auto adapter.
///
/// The legacy top-level snapshot remains present while the Android car surface
/// migrates. Keeping this payload separate from CarPlay lets each native host
/// evolve its lifecycle without making the other platform guess at semantics.
Map<String, Object?> projectAndroidAutoNavigationV2({
  required String sourceId,
  required int sequence,
  required DateTime generatedAt,
  required String ridePhase,
  required ImportedRoute? route,
  required bool navigationEnabled,
  required NavigationGuidance? guidance,
  required DistanceUnit? distanceUnit,
  required String? localeIdentifier,
  required double? speedMetersPerSecond,
  required RouteJourneyProgress? journeyProgress,
  required RouteProgressGeometry? routeProgress,
  required bool followRider,
  required bool canPlanRoute,
  required bool canFreeRoam,
  required bool canStartPreparedRide,
  required Map<String, Object?>? alert,
}) {
  final navigationPhase = switch ((route, ridePhase, navigationEnabled)) {
    (null, _, _) => 'inactive',
    (_, 'endedRide', _) => 'ended',
    (_, _, false) => 'ended',
    (_, 'activeRide', true) => 'navigating',
    _ => 'routeReady',
  };
  final trafficSide = _trafficSide(
    guidance?.instruction,
    route?.maneuvers.firstOrNull,
  );
  final navigating = navigationPhase == 'navigating';

  return {
    'schemaVersion': 2,
    'sourceId': sourceId,
    'sequence': sequence,
    'generatedAtMillis': generatedAt.millisecondsSinceEpoch,
    'rideLifecycle': {'phase': ridePhase},
    'navigationLifecycle': {
      'phase': navigationPhase,
      // This is a desired host state, not the ride lifecycle. Android may lose
      // navigation ownership while the phone continues recording the ride.
      'shouldOwnNavigation': navigating,
    },
    'route': route == null
        ? null
        : {
            'id': route.id,
            'navigationSessionId': '${route.id}:android-navigation',
            'restorationId': route.id,
            'name': route.name,
            'trafficSide': trafficSide,
          },
    'currentManeuver': guidance == null
        ? null
        : _maneuverSnapshot(
            maneuver: guidance.maneuver,
            instruction: guidance.instruction,
            distanceMeters: guidance.distanceMeters,
            secondsRemaining: guidanceSecondsRemaining(
              distanceMeters: guidance.distanceMeters,
              speedMetersPerSecond: speedMetersPerSecond,
            ),
          ),
    'followingManeuver': switch ((
      guidance?.followingManeuver,
      guidance?.followingInstruction,
    )) {
      (final maneuver?, final instruction?) => _maneuverSnapshot(
        maneuver: maneuver,
        instruction: instruction,
        distanceMeters: guidance?.followingDistanceMeters,
      ),
      _ => null,
    },
    'journey': journeyProgress?.toSnapshot(),
    'progress': {
      'travelledMeters': _nonNegativeFinite(routeProgress?.progressMeters),
      'totalMeters': _nonNegativeFinite(routeProgress?.totalMeters),
    },
    'units': {
      'distance': distanceUnit?.name,
      'speed': switch (distanceUnit) {
        DistanceUnit.miles => 'milesPerHour',
        DistanceUnit.kilometres => 'kilometresPerHour',
        null => null,
      },
    },
    'localeIdentifier': localeIdentifier,
    'camera': {'followRider': followRider},
    'actions': {
      'canPlanRoute': canPlanRoute,
      'canFreeRoam': canFreeRoam,
      'canStartPreparedRide': canStartPreparedRide,
      'canCancelNavigation': navigating,
      'canLeaveRide': ridePhase == 'activeRide',
    },
    'alert': alert,
  };
}

Map<String, Object?> _maneuverSnapshot({
  required RouteManeuver maneuver,
  required ManeuverInstruction instruction,
  required double? distanceMeters,
  double? secondsRemaining,
}) => {
  'id': maneuver.identity,
  'kind': instruction.kind.name,
  'direction': instruction.direction.name,
  'engineType': maneuver.type,
  'engineModifier': maneuver.modifier,
  'instructionVariants': _variants([
    instruction.text,
    instruction.standaloneText,
  ]),
  'roadNameVariants': _variants([
    instruction.roadLabel,
    instruction.roadName,
    instruction.roadRef,
  ]),
  'position': {
    'latitude': maneuver.position.latitude,
    'longitude': maneuver.position.longitude,
  },
  'exitNumber': instruction.exitNumber ?? maneuver.exitNumber,
  'trafficSide': _trafficSide(instruction, maneuver),
  'distanceMeters': _nonNegativeFinite(distanceMeters),
  'secondsRemaining': _nonNegativeFinite(secondsRemaining),
  'bearingBeforeDegrees': _finite(maneuver.bearingBeforeDegrees),
  'bearingAfterDegrees': _finite(maneuver.bearingAfterDegrees),
  'departureBearingDegrees': _finite(instruction.departureBearingDegrees),
  'stepCount': instruction.stepCount,
  'lanes': [
    for (final lane in instruction.lanes)
      {'indications': lane.indications, 'valid': lane.valid},
  ],
};

List<String> _variants(Iterable<String?> candidates) {
  final variants = <String>[];
  for (final candidate in candidates) {
    final value = candidate?.trim();
    if (value == null || value.isEmpty || variants.contains(value)) continue;
    variants.add(value);
  }
  return variants;
}

String _trafficSide(ManeuverInstruction? instruction, RouteManeuver? maneuver) {
  final explicit = instruction?.leftHandTraffic;
  if (explicit != null) return explicit ? 'left' : 'right';
  return switch (maneuver?.drivingSide?.trim().toLowerCase()) {
    'left' => 'left',
    'right' => 'right',
    _ => 'unknown',
  };
}

double? _nonNegativeFinite(double? value) {
  final finite = _finite(value);
  return finite != null && finite >= 0 ? finite : null;
}

double? _finite(double? value) => value?.isFinite == true ? value : null;

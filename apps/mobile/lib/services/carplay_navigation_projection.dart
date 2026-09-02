import '../domain/distance_unit.dart';
import '../domain/imported_route.dart';
import 'guidance_time_remaining.dart';
import 'navigation_guidance.dart';
import 'route_journey_progress.dart';

/// Navigation state intended only for the native CarPlay adapter.
///
/// This payload is deliberately additive to the legacy shared snapshot. Android
/// Auto can continue decoding the existing top-level fields while CarPlay moves
/// to typed manoeuvres and explicit lifecycle state one capability at a time.
Map<String, Object?> projectCarPlayNavigationV2({
  required String sourceId,
  required int sequence,
  required DateTime generatedAt,
  required String ridePhase,
  required ImportedRoute? route,
  required NavigationGuidance? guidance,
  required DistanceUnit? distanceUnit,
  required String? localeIdentifier,
  required double? speedMetersPerSecond,
  required RouteJourneyProgress? journeyProgress,
}) {
  final navigationPhase = switch ((route, ridePhase)) {
    (null, _) => 'inactive',
    (_, 'endedRide') => 'ended',
    (_, 'activeRide') => 'navigating',
    _ => 'routeReady',
  };
  final trafficSide = _trafficSide(
    guidance?.instruction,
    route?.maneuvers.firstOrNull,
  );

  return {
    'schemaVersion': 2,
    'sourceId': sourceId,
    'sequence': sequence,
    'generatedAtMillis': generatedAt.millisecondsSinceEpoch,
    'rideLifecycle': {'phase': ridePhase},
    'navigationLifecycle': {'phase': navigationPhase},
    'trip': route == null
        ? null
        : {
            'id': route.id,
            'routeChoiceId': '${route.id}:primary',
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
    'units': {
      'distance': distanceUnit?.name,
      'speed': switch (distanceUnit) {
        DistanceUnit.miles => 'milesPerHour',
        DistanceUnit.kilometres => 'kilometresPerHour',
        null => null,
      },
    },
    'localeIdentifier': localeIdentifier,
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

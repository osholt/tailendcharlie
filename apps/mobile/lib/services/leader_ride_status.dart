import 'dart:math' as math;

import '../domain/geo_point.dart';
import '../domain/ride_role.dart';
import '../domain/rider_location.dart';
import '../domain/route_alert.dart';
import 'geo_calculations.dart';
import 'leader_track_exemption.dart';

class LeaderOffCourseAlert {
  const LeaderOffCourseAlert({
    required this.riderId,
    required this.displayName,
    required this.level,
    this.distanceFromRouteMeters,
  });

  final String riderId;
  final String displayName;
  final RouteAlertLevel level;
  final double? distanceFromRouteMeters;
}

/// Whether a ride has a Tail End Charlie, and how usable that TEC's position
/// is. The app is named after the back-marker role, so "nobody is TEC" is a
/// different safety situation from "the TEC has not reported a position yet",
/// and the two must never be conflated.
///
/// Consumers must branch on this rather than infer a state from a null name,
/// distance or age.
enum TecAvailability {
  /// No rider holds the Tail End Charlie role. Every distance-to-TEC surface
  /// is hidden rather than shown empty, dashed or zeroed, and features that
  /// target the TEC (for example rejoin routing for a massively off-course
  /// rider) must fall back to the ride leader instead of a null target.
  none,

  /// A rider holds the role but has not reported a position yet, so there is
  /// no gap and no age to show. Surfaces show the waiting state anchored by
  /// issue #88. [LeaderRideStatus.tecName], [LeaderRideStatus.tecLocationAge],
  /// [LeaderRideStatus.distanceToTecMeters] and
  /// [LeaderRideStatus.estimatedTimeToTec] are all null;
  /// [LeaderRideStatus.tecRiderId] identifies the registered TEC.
  awaitingLocation,

  /// The TEC's last known position is older than
  /// [LeaderRideStatusCalculator.staleAfter]. Surfaces show that age honestly
  /// and deliberately withhold a gap that can no longer be trusted, so
  /// [LeaderRideStatus.tecLocationAge] is set while
  /// [LeaderRideStatus.distanceToTecMeters] and
  /// [LeaderRideStatus.estimatedTimeToTec] are null.
  stale,

  /// The TEC's position is fresh. [LeaderRideStatus.tecLocationAge] is set,
  /// and the gap is present whenever the leader also has a position of their
  /// own to measure from.
  tracking,
}

/// Who the Tail End Charlie is, how usable their position is, and their last
/// known fix.
///
/// Resolved once by [LeaderRideStatusCalculator.resolveTecTarget] so the
/// leader's TEC card and any feature that routes to the back-marker (rejoin
/// routing for a massively off-course rider, #102) cannot disagree about
/// whether there is a TEC or whether its position can be believed.
class TecTarget {
  const TecTarget({required this.availability, this.riderId, this.location});

  final TecAvailability availability;

  /// The rider holding the role, for every registered state including
  /// [TecAvailability.awaitingLocation].
  final String? riderId;

  /// The TEC's newest known fix. Null for [TecAvailability.none] and
  /// [TecAvailability.awaitingLocation]; deliberately still set for
  /// [TecAvailability.stale] so a caller can decide for itself what an ageing
  /// fix is good enough for.
  final RiderLocation? location;

  bool get hasRegisteredTec => availability != TecAvailability.none;

  /// The fix a feature may navigate to: fresh only.
  ///
  /// A stale position is withheld here for the same reason the leader's gap is
  /// withheld - it can no longer be trusted to say where the TEC is - so a
  /// caller falls back to the ride leader rather than routing a rider to where
  /// the TEC used to be.
  RiderLocation? get navigableLocation =>
      availability == TecAvailability.tracking ? location : null;
}

class LeaderRideStatus {
  const LeaderRideStatus({
    required this.offCourseAlerts,
    this.tecName,
    this.distanceToTecMeters,
    this.estimatedTimeToTec,
    this.tecLocationAge,
    this.tecRiderId,
    TecAvailability? tecAvailability,
  }) : tecAvailability =
           tecAvailability ??
           (tecName == null
               ? TecAvailability.none
               : distanceToTecMeters == null || estimatedTimeToTec == null
               ? TecAvailability.stale
               : TecAvailability.tracking);

  /// The single authoritative discriminator for every TEC surface and every
  /// TEC-targeting feature.
  final TecAvailability tecAvailability;

  /// The rider holding the TEC role. Non-null for every registered state,
  /// including [TecAvailability.awaitingLocation], so a feature that targets
  /// the TEC has a real rider id instead of a null target.
  final String? tecRiderId;

  /// The TEC's display name once a position for them is known. Deliberately
  /// null while [tecAvailability] is [TecAvailability.awaitingLocation]:
  /// nothing is known about where that TEC is, so a surface must show the
  /// waiting state rather than name a position it does not have.
  final String? tecName;
  final double? distanceToTecMeters;
  final Duration? estimatedTimeToTec;
  final Duration? tecLocationAge;
  final List<LeaderOffCourseAlert> offCourseAlerts;

  /// Whether any rider is Tail End Charlie. False means the ride has no
  /// back-marker at all: hide the TEC surfaces and fall back to the leader.
  bool get hasRegisteredTec => tecAvailability != TecAvailability.none;
}

class LeaderRideStatusCalculator {
  const LeaderRideStatusCalculator({
    this.defaultMovingSpeedMetersPerSecond = 13.4,
    this.maximumOnRouteDistanceMeters = 250,
    this.staleAfter = const Duration(minutes: 2),
    this.leaderTrackCorridorMeters = 120,
  });

  final double defaultMovingSpeedMetersPerSecond;
  final double maximumOnRouteDistanceMeters;
  final Duration staleAfter;

  /// Corridor around the leader's own recorded track inside which a rider is
  /// following the leader rather than off course. See [LeaderTrackExemption].
  final double leaderTrackCorridorMeters;

  /// [leaderTrail] is the leader's own recorded track. A rider inside its
  /// corridor is following the leader and is never counted as off course, even
  /// if a deviation alert for them arrived from a device that had not yet seen
  /// the leader leave the GPX.
  LeaderRideStatus? calculate({
    required RideRole localRole,
    required String localRiderId,
    required RiderLocation? localLocation,
    required List<RiderLocation> riderLocations,
    required List<RiderRouteAlert> routeAlerts,
    required List<GeoPoint> route,
    List<GeoPoint> leaderTrail = const [],
    // Rider ids holding the TEC role in the reconciled membership model
    // (issue #27), which is the authoritative record of who is registered. A
    // TEC who has joined but not yet reported a position appears here and
    // nowhere else, so passing it is what separates
    // TecAvailability.awaitingLocation from TecAvailability.none. A rider
    // carrying the TEC role in riderLocations also counts as registered, so a
    // caller with only a location snapshot still resolves a TEC rather than
    // silently reporting none.
    Iterable<String> registeredTecRiderIds = const [],
    DateTime? now,
  }) {
    if (localRole != RideRole.lead) return null;
    final evaluatedAt = now ?? DateTime.now();
    final currentRiderIds = riderLocations
        .map((location) => location.riderId)
        .toSet();
    final locationsById = {
      for (final location in riderLocations) location.riderId: location,
    };
    final currentOffCourseAlerts = <String, RiderRouteAlert>{};
    for (final alert in routeAlerts) {
      if (alert.riderId == localRiderId ||
          !currentRiderIds.contains(alert.riderId) ||
          alert.acknowledged ||
          alert.assessment.state != RouteTrackingState.offRoute ||
          !alert.assessment.coordinatorActionRequired) {
        continue;
      }
      final location = locationsById[alert.riderId];
      if (location != null &&
          LeaderTrackExemption.isFollowingLeaderTrack(
            position: location.sample.position,
            accuracyMeters: location.sample.accuracyMeters,
            leaderTrack: leaderTrail,
            corridorMeters: leaderTrackCorridorMeters,
          )) {
        continue;
      }
      final previous = currentOffCourseAlerts[alert.riderId];
      if (previous == null ||
          alert.assessment.evaluatedAt.isAfter(
            previous.assessment.evaluatedAt,
          )) {
        currentOffCourseAlerts[alert.riderId] = alert;
      }
    }
    final offCourseAlerts =
        currentOffCourseAlerts.values
            .map(
              (alert) => LeaderOffCourseAlert(
                riderId: alert.riderId,
                displayName: alert.displayName,
                level: alert.assessment.alertLevel,
                distanceFromRouteMeters:
                    alert.assessment.distanceFromRouteMeters,
              ),
            )
            .toList(growable: false)
          ..sort((first, second) {
            final byLevel = second.level.index.compareTo(first.level.index);
            return byLevel != 0
                ? byLevel
                : first.displayName.compareTo(second.displayName);
          });

    final tecTarget = resolveTecTarget(
      localRiderId: localRiderId,
      riderLocations: riderLocations,
      registeredTecRiderIds: registeredTecRiderIds,
      now: evaluatedAt,
    );
    if (!tecTarget.hasRegisteredTec) {
      // No back-marker at all. Everything TEC-shaped stays null so no surface
      // can render an empty gap and no feature can take a null target.
      return LeaderRideStatus(offCourseAlerts: offCourseAlerts);
    }
    final tec = tecTarget.location;
    if (tec == null) {
      return LeaderRideStatus(
        tecAvailability: TecAvailability.awaitingLocation,
        tecRiderId: tecTarget.riderId,
        offCourseAlerts: offCourseAlerts,
      );
    }

    final age = tec.sample.ageAt(evaluatedAt);
    if (tecTarget.availability == TecAvailability.stale) {
      return LeaderRideStatus(
        tecAvailability: TecAvailability.stale,
        tecRiderId: tec.riderId,
        tecName: tec.displayName,
        tecLocationAge: age,
        offCourseAlerts: offCourseAlerts,
      );
    }
    if (localLocation == null) {
      // The TEC's position is fresh; only the leader's own fix is missing, so
      // the gap is withheld while the age stays honest.
      return LeaderRideStatus(
        tecAvailability: TecAvailability.tracking,
        tecRiderId: tec.riderId,
        tecName: tec.displayName,
        tecLocationAge: age,
        offCourseAlerts: offCourseAlerts,
      );
    }

    final distance = _distanceBetween(localLocation, tec, route);
    final movingSpeeds = [
      localLocation.sample.speedMetersPerSecond,
      tec.sample.speedMetersPerSecond,
    ].whereType<double>().where((speed) => speed >= 2).toList(growable: false);
    final speed = movingSpeeds.isEmpty
        ? defaultMovingSpeedMetersPerSecond
        : movingSpeeds.reduce((a, b) => a + b) / movingSpeeds.length;
    final seconds = distance < 25 ? 0 : (distance / speed).round();
    return LeaderRideStatus(
      tecAvailability: TecAvailability.tracking,
      tecRiderId: tec.riderId,
      tecName: tec.displayName,
      distanceToTecMeters: distance,
      estimatedTimeToTec: Duration(seconds: seconds),
      tecLocationAge: age,
      offCourseAlerts: offCourseAlerts,
    );
  }

  /// Resolves the Tail End Charlie once, by the rules every TEC surface and
  /// every TEC-targeting feature shares.
  ///
  /// [registeredTecRiderIds] is the authoritative membership record, which is
  /// what separates "nobody is TEC" from "the TEC has not reported yet". A
  /// rider carrying the role in [riderLocations] also counts, so a caller
  /// holding only a location snapshot still resolves a TEC. [localRiderId] is
  /// excluded throughout: a rider is never their own back-marker.
  TecTarget resolveTecTarget({
    required String localRiderId,
    required List<RiderLocation> riderLocations,
    required DateTime now,
    Iterable<String> registeredTecRiderIds = const [],
  }) {
    final candidates =
        riderLocations
            .where(
              (location) =>
                  location.riderId != localRiderId &&
                  location.role == RideRole.tailEndCharlie,
            )
            .toList(growable: false)
          ..sort(
            (first, second) =>
                second.sample.recordedAt.compareTo(first.sample.recordedAt),
          );
    final registeredIds =
        {
            ...registeredTecRiderIds,
            ...candidates.map((location) => location.riderId),
          }.where((riderId) => riderId != localRiderId).toList(growable: false)
          ..sort();
    if (registeredIds.isEmpty) {
      return const TecTarget(availability: TecAvailability.none);
    }
    final tec = candidates.firstOrNull;
    if (tec == null) {
      return TecTarget(
        availability: TecAvailability.awaitingLocation,
        riderId: registeredIds.first,
      );
    }
    return TecTarget(
      availability: tec.sample.ageAt(now) > staleAfter
          ? TecAvailability.stale
          : TecAvailability.tracking,
      riderId: tec.riderId,
      location: tec,
    );
  }

  double _distanceBetween(
    RiderLocation lead,
    RiderLocation tec,
    List<GeoPoint> route,
  ) {
    if (route.length >= 2) {
      final leadProjection = GeoCalculations.projectOntoPolyline(
        lead.sample.position,
        route,
      );
      final tecProjection = GeoCalculations.projectOntoPolyline(
        tec.sample.position,
        route,
      );
      if (leadProjection.distanceFromRouteMeters <=
              maximumOnRouteDistanceMeters &&
          tecProjection.distanceFromRouteMeters <=
              maximumOnRouteDistanceMeters) {
        final alongRouteDistance =
            (leadProjection.distanceAlongRouteMeters -
                    tecProjection.distanceAlongRouteMeters)
                .abs();
        if (GeoCalculations.distanceMeters(route.first, route.last) <= 25) {
          var routeDistance = 0.0;
          for (var index = 1; index < route.length; index += 1) {
            routeDistance += GeoCalculations.distanceMeters(
              route[index - 1],
              route[index],
            );
          }
          return math.min(
            alongRouteDistance,
            math.max(0, routeDistance - alongRouteDistance),
          );
        }
        return alongRouteDistance;
      }
    }
    return GeoCalculations.distanceMeters(
      lead.sample.position,
      tec.sample.position,
    );
  }
}

import 'dart:math' as math;

import '../domain/geo_point.dart';
import '../domain/hazard.dart';
import 'geo_calculations.dart';

/// Why a hazard report is, or is not, drawn on the ride map.
///
/// Only [visible] draws. The hidden reasons are separate values rather than one
/// bool because each of them is a different mistake if it is got wrong, and each
/// is asserted on its own in `hazard_map_relevance_test.dart`.
enum HazardMapVisibility {
  /// Ahead along the route, or in front by bearing, or no direction evidence at
  /// all - in which case it is drawn, because #112 settled that a real sighting
  /// must never be dropped for want of a heading.
  visible,

  /// Already ridden past.
  behind,

  /// Beside the rider but on a stretch the rider is not on: the other
  /// carriageway of a dual carriageway, a parallel road, or the return leg of an
  /// out-and-back.
  oppositeCarriageway,

  /// Real and ahead, but too far away to be worth ink yet.
  beyondRange,

  /// Past its documented expiry.
  expired,
}

/// A hazard report judged against where the rider is and which way they are
/// going.
class HazardMapJudgement {
  const HazardMapJudgement({
    required this.report,
    required this.visibility,
    this.distanceAheadMeters,
  });

  final HazardReport report;
  final HazardMapVisibility visibility;

  /// Distance still to run: measured along the route where one is loaded and the
  /// report sits on it, straight-line otherwise, and null when the rider's
  /// position is unknown. Never negative.
  final double? distanceAheadMeters;

  bool get isVisible => visibility == HazardMapVisibility.visible;
}

/// Decides which hazard reports the ride map draws.
///
/// This is the map's half of the judgement #112 made for the full-screen
/// warning, and it is deliberately the same judgement: ahead along the loaded
/// route, falling back to bearing versus heading, with a report that has been
/// passed or sits on the opposite carriageway dropped rather than drawn as
/// though it were ahead (#135).
///
/// It differs from [EnforcementAlertDetector] in three ways, all of them
/// intentional:
///
/// 1. It judges every report rather than returning the nearest one, because a
///    map draws all of them.
/// 2. It looks further out - a symbol has to be on screen *before* the warning
///    fires, which is the whole point of the issue.
/// 3. It considers every pass the route makes near a report, not just the
///    geometrically nearest one. On an out-and-back the nearest projection puts
///    a report the rider is about to reach behind them; see
///    [GeoCalculations.passesNear].
///
/// ## Opposite carriageway
///
/// Two independent signals have to agree before a report is dropped as being on
/// the opposite carriageway, because dropping a real camera is the worse error:
///
/// - the route, where one is loaded: the pass the report sits on runs against
///   the direction the rider is travelling, so the rider will only reach it
///   after turning round;
/// - the geometry: the report is not in front of the rider, its bearing being
///   more than [aheadHeadingToleranceDegrees] off the direction of travel.
///
/// A report round a bend fails the second test - it is in front of you - so a
/// twisty road cannot hide a genuine sighting, while a camera on the far side of
/// a dual carriageway the rider has already passed fails both.
///
/// What this cannot decide, honestly stated: a camera on the opposite
/// carriageway several hundred metres *ahead* is, to within the GPS corridor,
/// geometrically identical to one on the rider's own carriageway. A report
/// carries only a position - no reporter heading and no carriageway - so
/// nothing here can separate those two, and the conservative choice is to draw
/// it.
class HazardMapRelevance {
  const HazardMapRelevance({
    this.visibilityRangeMeters = 5000,
    this.routeCorridorMeters = 250,
    this.aheadHeadingToleranceDegrees = 75,
    this.behindHeadingToleranceDegrees = 115,
    this.oppositeRouteDirectionDegrees = 120,
    this.passedToleranceMeters = 25,
  });

  /// How far ahead a report is drawn. Comfortably more than the one mile #112
  /// warns at, so the symbol is already on the map when the warning arrives, and
  /// well beyond what a phone shows at ride zoom.
  final double visibilityRangeMeters;

  /// How far off the loaded route a report may sit and still count as on it.
  /// Matches [EnforcementAlertDetector.routeCorridorMeters].
  final double routeCorridorMeters;

  /// How far a report's bearing may differ from the direction of travel and
  /// still count as in front of the rider.
  final double aheadHeadingToleranceDegrees;

  /// Beyond this the report is behind rather than off to the side.
  final double behindHeadingToleranceDegrees;

  /// How far a route pass's bearing may differ from the rider's direction of
  /// travel before that pass is treated as the other way down the same road.
  final double oppositeRouteDirectionDegrees;

  /// A report this far behind the rider still counts as ahead. A report being
  /// ridden over sits at zero, and GPS noise must not make it flicker.
  final double passedToleranceMeters;

  /// Judges [reports] and returns them in the order given.
  List<HazardMapJudgement> judgeAll({
    required Iterable<HazardReport> reports,
    required GeoPoint? riderPosition,
    required DateTime now,
    double? headingDegrees,
    List<GeoPoint> route = const [],
  }) {
    final rider = locateRider(
      riderPosition: riderPosition,
      route: route,
      headingDegrees: headingDegrees,
    );
    return [
      for (final report in reports)
        judge(
          report: report,
          riderPosition: riderPosition,
          now: now,
          headingDegrees: headingDegrees,
          route: route,
          rider: rider,
        ),
    ];
  }

  HazardMapJudgement judge({
    required HazardReport report,
    required GeoPoint? riderPosition,
    required DateTime now,
    double? headingDegrees,
    List<GeoPoint> route = const [],
    RiderOnRoute? rider,
  }) {
    if (!report.isActiveAt(now)) {
      return HazardMapJudgement(
        report: report,
        visibility: HazardMapVisibility.expired,
      );
    }
    if (riderPosition == null) {
      // Nothing to judge against: a static map, or the first fix has not
      // arrived. Draw it rather than pretend to know it is irrelevant.
      return HazardMapJudgement(
        report: report,
        visibility: HazardMapVisibility.visible,
      );
    }

    final located =
        rider ??
        locateRider(
          riderPosition: riderPosition,
          route: route,
          headingDegrees: headingDegrees,
        );
    final riderAlong = located?.distanceAlongRouteMeters;
    // The direction the rider is travelling. The route beats the compass where
    // the rider is demonstrably on a loaded route: a phone heading on a bike
    // swings about, and the leg the rider is on is a steadier answer.
    final travelDirection =
        located?.bearingDegrees ??
        (headingDegrees != null && headingDegrees.isFinite
            ? headingDegrees
            : null);
    final straightLineMeters = GeoCalculations.distanceMeters(
      riderPosition,
      report.position,
    );
    // Unknown direction reads as "in front", so a missing heading can only ever
    // make this draw something, never hide something.
    final inFrontOfRider =
        travelDirection == null ||
        GeoCalculations.bearingDifferenceDegrees(
              travelDirection,
              GeoCalculations.bearingDegrees(riderPosition, report.position),
            ) <=
            aheadHeadingToleranceDegrees;

    if (riderAlong != null) {
      final passes = GeoCalculations.passesNear(
        report.position,
        route,
        corridorMeters: routeCorridorMeters,
        reversalToleranceDegrees: oppositeRouteDirectionDegrees,
      );
      final ahead =
          passes
              .where(
                (pass) =>
                    pass.distanceAlongRouteMeters - riderAlong >=
                    -passedToleranceMeters,
              )
              .toList()
            ..sort(
              (first, second) => first.distanceAlongRouteMeters.compareTo(
                second.distanceAlongRouteMeters,
              ),
            );
      if (passes.isNotEmpty) {
        if (ahead.isEmpty) {
          return HazardMapJudgement(
            report: report,
            visibility: HazardMapVisibility.behind,
          );
        }
        // A pass running the rider's way wins over a nearer one running against
        // it, so a report the rider will reach on this leg is never dropped
        // because the route also touches it on the way home.
        final chosen = ahead.firstWhere(
          (pass) => !_runsAgainstTravel(pass, travelDirection),
          orElse: () => ahead.first,
        );
        if (_runsAgainstTravel(chosen, travelDirection) && !inFrontOfRider) {
          return HazardMapJudgement(
            report: report,
            visibility: HazardMapVisibility.oppositeCarriageway,
          );
        }
        final remaining = math.max(
          0.0,
          chosen.distanceAlongRouteMeters - riderAlong,
        );
        return HazardMapJudgement(
          report: report,
          visibility: remaining > visibilityRangeMeters
              ? HazardMapVisibility.beyondRange
              : HazardMapVisibility.visible,
          distanceAheadMeters: remaining,
        );
      }
      // The report is off the route corridor: the rider may have diverted onto
      // the road it sits on, so fall through to the bearing test rather than
      // dropping it.
    }

    if (travelDirection == null) {
      return HazardMapJudgement(
        report: report,
        visibility: straightLineMeters > visibilityRangeMeters
            ? HazardMapVisibility.beyondRange
            : HazardMapVisibility.visible,
        distanceAheadMeters: straightLineMeters,
      );
    }
    final difference = GeoCalculations.bearingDifferenceDegrees(
      travelDirection,
      GeoCalculations.bearingDegrees(riderPosition, report.position),
    );
    if (difference >= behindHeadingToleranceDegrees) {
      return HazardMapJudgement(
        report: report,
        visibility: HazardMapVisibility.behind,
      );
    }
    if (difference > aheadHeadingToleranceDegrees) {
      return HazardMapJudgement(
        report: report,
        visibility: HazardMapVisibility.oppositeCarriageway,
      );
    }
    return HazardMapJudgement(
      report: report,
      visibility: straightLineMeters > visibilityRangeMeters
          ? HazardMapVisibility.beyondRange
          : HazardMapVisibility.visible,
      distanceAheadMeters: straightLineMeters,
    );
  }

  bool _runsAgainstTravel(PolylinePass pass, double? travelDirection) {
    final bearing = pass.bearingDegrees;
    if (bearing == null || travelDirection == null) return false;
    return GeoCalculations.bearingDifferenceDegrees(bearing, travelDirection) >
        oppositeRouteDirectionDegrees;
  }

  /// Where on [route] the rider is, and which way that leg runs.
  ///
  /// Null when there is no usable route or the rider is not on it, in which case
  /// the whole route-based half of the judgement is skipped.
  ///
  /// The heading is what picks between legs, and on an out-and-back it has to:
  /// a rider halfway home down the same road they rode out on is exactly as close
  /// to the outbound leg as to the return one, so geometry alone cannot say which
  /// they are on, and picking the outbound one puts every report on the way home
  /// behind them. Without a heading this falls back to the closest leg, which is
  /// all there is to go on.
  RiderOnRoute? locateRider({
    required GeoPoint? riderPosition,
    required List<GeoPoint> route,
    double? headingDegrees,
  }) {
    if (riderPosition == null || route.length < 2) return null;
    final passes = GeoCalculations.passesNear(
      riderPosition,
      route,
      corridorMeters: routeCorridorMeters,
      reversalToleranceDegrees: oppositeRouteDirectionDegrees,
    );
    if (passes.isEmpty) return null;
    final heading = headingDegrees != null && headingDegrees.isFinite
        ? headingDegrees
        : null;
    // Legs pointing the rider's way sort ahead of legs that do not, and within
    // each group the closest leg wins.
    double rank(PolylinePass pass) {
      final bearing = pass.bearingDegrees;
      final disagrees =
          heading != null &&
          bearing != null &&
          GeoCalculations.bearingDifferenceDegrees(bearing, heading) >
              aheadHeadingToleranceDegrees;
      return (disagrees ? 1e9 : 0) + pass.distanceFromRouteMeters;
    }

    final best = passes.reduce((a, b) => rank(b) < rank(a) ? b : a);
    return RiderOnRoute(
      distanceAlongRouteMeters: best.distanceAlongRouteMeters,
      bearingDegrees: best.bearingDegrees,
    );
  }
}

/// Where the rider sits on the loaded route.
class RiderOnRoute {
  const RiderOnRoute({
    required this.distanceAlongRouteMeters,
    required this.bearingDegrees,
  });

  final double distanceAlongRouteMeters;

  /// Which way the leg the rider is on runs.
  final double? bearingDegrees;
}

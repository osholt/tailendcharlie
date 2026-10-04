import 'package:meta/meta.dart';

import '../domain/geo_point.dart';
import '../domain/marker_assistance.dart';
import '../domain/rider_location.dart';
import '../relay/live_presence.dart';
import 'geo_calculations.dart';
import 'ride_completion_detector.dart';
import 'route_progress.dart';

/// Every threshold behind "has this group finished with this rider?", in one
/// place and with the reason for each number (#859).
///
/// The failure this exists for is a phone that keeps sharing a position for
/// hours after the group has gone home, because nobody ended the ride. The
/// failure it must **never** cause is the opposite one: a rider who is actually
/// out riding, with the phone in a tank bag, having their sharing stopped. The
/// two are not symmetric. A forgotten ride costs a few hours of a friend's
/// location; an interrupted one costs a rider the group could no longer see. So
/// every number below errs towards *not* deciding that a ride has ended, and the
/// stop itself waits for the rider to be parked.
class SharingDispersalPolicy {
  const SharingDispersalPolicy({
    this.promptAfter = const Duration(minutes: 30),
    this.answerWithin = const Duration(minutes: 15),
    this.keepSharingSnooze = const Duration(hours: 2),
    this.togetherRadiusMeters = 2000,
    this.groupReachMeters = 25000,
    this.movingSpeedMetersPerSecond = 2,
    this.companyMemory = const Duration(hours: 2),
    this.routeCorridorMeters =
        RouteProgressTracker.defaultMaximumTrackingDistanceMeters,
    this.routeCompleteFraction =
        RideCompletionDetector.defaultMinimumRouteProgressFraction,
    this.routeStopAllowance = const Duration(hours: 3),
    this.markerWaitCeiling = const Duration(minutes: 90),
    this.pauseAllowance = const Duration(hours: 2),
    this.parkedRadiusMeters = 150,
    this.ridingWindow = const Duration(minutes: 5),
    this.continuityGap = const Duration(minutes: 5),
  });

  /// How long the rider must have been away from the ride, continuously, before
  /// they are asked about it. 30 minutes.
  ///
  /// Long enough that no stop that belongs to a ride reaches it. A fuel stop is
  /// ten minutes and a coffee stop twenty to thirty, and those are spent *with*
  /// the group, which is not "away" at all - so this is a second margin on top of
  /// the group test, not the only one. Short enough that "hours" cannot happen:
  /// this plus [answerWithin] is 45 minutes from the group dispersing to the last
  /// position leaving the phone.
  final Duration promptAfter;

  /// How long a rider has to answer once they have stopped moving. 15 minutes.
  ///
  /// The countdown is measured from the later of the question and the moment the
  /// rider last moved. A rider on the road cannot read a prompt, so for them the
  /// question stays up and nothing is decided; an unanswered question is not a
  /// refusal. Fifteen minutes is long enough to take gloves off and look at a
  /// phone after a stop, short enough to be a bounded promise.
  final Duration answerWithin;

  /// How long "Keep sharing" holds the question off. Two hours.
  ///
  /// A rider who has just said they are still riding must not be nagged, and
  /// two hours covers a long stop and a ride home. It is still bounded: a rider
  /// who says yes and then forgets is asked again within the afternoon.
  final Duration keepSharingSnooze;

  /// Another rider this close, and seen recently, is company. 2 km.
  ///
  /// A group strings out. Lead and Tail End Charlie on a country road are
  /// routinely a kilometre or more apart, and the app's own TEC-gap surfaces
  /// treat that as normal. 2 km keeps a stretched group "together" without
  /// counting two riders in separate villages as one group.
  final double togetherRadiusMeters;

  /// How far away a rider who is **moving** still counts as the group being out
  /// riding. 25 km.
  ///
  /// This is what protects a rider who has fallen behind or taken a wrong turn:
  /// they are not with anyone, but the group is still out there, and sharing is
  /// how they get found. 25 km is half an hour at an average 50 km/h - further
  /// than a rider trying to rejoin plausibly is from the nearest moving rider.
  /// A moving rider far beyond it is not part of the same ride any more.
  final double groupReachMeters;

  /// Under this a rider is not travelling. 2 m/s (7 km/h).
  ///
  /// The same figure `LeaderRideStatusCalculator` uses for "moving", above
  /// walking pace and below any real riding.
  final double movingSpeedMetersPerSecond;

  /// How long a rider's last known position near this one still counts as
  /// company once nothing new has arrived from them. Two hours.
  ///
  /// A stopped phone does not necessarily keep reporting: position fixes follow
  /// distance travelled, so a group at a long lunch can go quiet on each other's
  /// screens. Silence must not be read as departure, because the cost of getting
  /// that wrong is stopping the sharing of a group that is sitting right here. A
  /// rider who actually leaves *moves*, and a moving phone reports, so the memory
  /// only ever covers people who have not gone anywhere. Two hours is longer than
  /// a stop that is part of a ride.
  final Duration companyMemory;

  /// How close to the route counts as on it. 150 m.
  ///
  /// The distance `RouteProgressTracker` stops advancing progress at - there is
  /// no route to be progressed along any further out - so "on the route" means
  /// the same thing here as it does for the progress shown to the rider.
  final double routeCorridorMeters;

  /// How much of the route must be behind the rider for the route to count as
  /// finished. 90%.
  ///
  /// Not a second opinion: this is `RideCompletionDetector`'s own threshold, and
  /// the leader's "everyone has finished" suggestion fires on it. A rider who has
  /// ridden the plan is not "on a route" any more, whatever the geometry says.
  final double routeCompleteFraction;

  /// How long a rider can sit still on an unfinished route and still be treated
  /// as riding it. Three hours.
  ///
  /// Being on the route is the strongest sign a rider is mid-ride, and a stop on
  /// it is a lunch, a puncture or a wait for recovery. Longer than any of those.
  /// Past it the phone has been left on the road, not the ride.
  final Duration routeStopAllowance;

  /// How long a marker waiting at a junction is treated as waiting for a group
  /// that is still coming. 90 minutes.
  ///
  /// A marker holds until the Tail End Charlie has passed, and a slow or
  /// stopped group can make that long. It is bounded because a marker session
  /// nobody ended is exactly a ride nobody ended.
  final Duration markerWaitCeiling;

  /// How long a pause the leader declared is treated as the group being stopped
  /// together rather than as a ride nobody ended. Two hours.
  ///
  /// A pause is a stop in a ride - lunch, fuel, a view - and the riders spread
  /// around it: some at the cafe, some at the fuel station, some sightseeing, all
  /// stationary and apart for longer than [promptAfter]. The leader said the
  /// group is stopped, so a rider is not told they have been left behind.
  /// It is bounded because a pause nobody resumed is exactly a ride nobody
  /// ended.
  final Duration pauseAllowance;

  /// How far a rider can wander and still be in the same place. 150 m, plus the
  /// fix's own error.
  ///
  /// A phone on a desk wanders by tens of metres, and indoors by more. The error
  /// of each fix is added on top, so a poor fix never reads as the rider
  /// leaving. A rider crawling in traffic or standing at lights moves further
  /// than this every few minutes, so they are never "in one place" for long.
  final double parkedRadiusMeters;

  /// How recently a rider must have moved to be told "while you are riding"
  /// rather than the plain countdown. Five minutes.
  ///
  /// Wording only: it decides which of two accurate sentences a rider reads, and
  /// nothing is stopped or kept going because of it.
  final Duration ridingWindow;

  /// The longest gap between evaluations that still counts as continuous. Five
  /// minutes.
  ///
  /// Evaluation runs every half minute. A longer gap means the app was
  /// suspended or blocked, and nobody can vouch for what the group did in it, so
  /// "away for 30 minutes" starts again rather than being inferred.
  final Duration continuityGap;
}

/// One other rider, as the dispersal rule sees them.
@immutable
class DispersalPeer {
  const DispersalPeer({
    required this.riderId,
    required this.freshness,
    this.position,
    this.age,
    this.speedMetersPerSecond,
  });

  /// Built from the one reconciled live model, so this rule and the map agree
  /// about who is where and how old that is.
  factory DispersalPeer.fromPresence(LiveRiderPresence presence) {
    final sample = presence.location?.sample;
    return DispersalPeer(
      riderId: presence.riderId,
      freshness: presence.freshness,
      position: sample?.position,
      age: presence.age,
      speedMetersPerSecond: sample?.speedMetersPerSecond,
    );
  }

  final String riderId;
  final PresenceFreshness freshness;

  /// Their newest known position, however old. Null when none ever arrived.
  final GeoPoint? position;

  /// How old [position] is, on the clock the reconciler judged it on.
  final Duration? age;

  final double? speedMetersPerSecond;

  /// Heard from in the last minute, so their speed means something.
  bool get isFresh => freshness.isTrackedAsContact;
}

/// The riders the rule should weigh: everyone in [presence] but this rider who
/// is still in the ride.
///
/// [liveRiderIds] is the ride's own list of who is still in it. A rider who has
/// left keeps a last known position on this phone, and it must not make anyone
/// look accompanied.
List<DispersalPeer> dispersalPeersFrom(
  Iterable<LiveRiderPresence> presence, {
  required Set<String> liveRiderIds,
}) => [
  for (final entry in presence)
    if (!entry.isLocal && liveRiderIds.contains(entry.riderId))
      DispersalPeer.fromPresence(entry),
];

/// The marker's wait, or null when this rider is not marking.
DispersalMarkerWait? dispersalMarkerFrom(MarkerSessionSummary? session) =>
    session == null
    ? null
    : DispersalMarkerWait(
        startedAt: session.startedAt,
        tecPassed: session.tecPassedAt != null,
      );

/// The planned route, from this rider's point of view.
@immutable
class DispersalRoute {
  const DispersalRoute({
    required this.withinCorridor,
    required this.progressFraction,
  });

  /// Reads the route situation off what `RouteProgressTracker` measured.
  ///
  /// Null for a route with no measurable length: there is nothing to follow, and
  /// a degenerate plan must not shield a rider from the rule for ever - the same
  /// reason `RideCompletionDetector` reads such a route as no progress at all.
  static DispersalRoute? fromProgress({
    required double distanceOffRouteMeters,
    required double progressMeters,
    required double totalMeters,
    SharingDispersalPolicy policy = const SharingDispersalPolicy(),
  }) {
    if (!totalMeters.isFinite || totalMeters <= 0) return null;
    if (!distanceOffRouteMeters.isFinite || !progressMeters.isFinite) {
      return null;
    }
    return DispersalRoute(
      withinCorridor: distanceOffRouteMeters <= policy.routeCorridorMeters,
      progressFraction: progressMeters / totalMeters,
    );
  }

  /// Whether the rider is on the route rather than somewhere else entirely.
  final bool withinCorridor;

  /// 0 to 1, monotonic, as `RouteProgressTracker` reports it.
  final double progressFraction;
}

/// A marker holding at a junction for the group, from the marker's own side.
@immutable
class DispersalMarkerWait {
  const DispersalMarkerWait({required this.startedAt, required this.tecPassed});

  final DateTime startedAt;

  /// The Tail End Charlie has gone by, so the group is no longer expected.
  final bool tecPassed;
}

/// Everything the rule needs. Built fresh for each evaluation; nothing in it is
/// remembered, so the same input always gives the same answer.
@immutable
class DispersalInput {
  const DispersalInput({
    required this.now,
    required this.groupRide,
    required this.local,
    required this.localParkedFor,
    required this.peers,
    required this.peersObservable,
    this.route,
    this.marker,
    this.ridePausedAt,
  });

  final DateTime now;

  /// False for a solo ride, which has no group to leave.
  final bool groupRide;

  /// This rider's newest fix, or null when there is none to judge by.
  final LocationSample? local;

  /// How long this rider has stayed in one place. Zero while moving.
  final Duration localParkedFor;

  /// Every rider but this one who is still in the ride.
  final List<DispersalPeer> peers;

  /// Whether this phone can currently see the group at all. When it cannot, "I
  /// see nobody" says nothing about the group.
  final bool peersObservable;

  final DispersalRoute? route;
  final DispersalMarkerWait? marker;

  /// When the leader paused the group, or null while the ride is not paused.
  final DateTime? ridePausedAt;
}

/// Why a rider is, or is not, judged to have been left behind by the ride.
enum DispersalState {
  /// A solo ride: nobody to disperse from, so nothing to stop.
  soloRide,

  /// Nothing to judge by - no position, or the group cannot be seen. Never a
  /// reason to stop anything.
  unknown,

  /// Another rider is here, or was here recently and has not gone anywhere.
  withGroup,

  /// Not with anyone, but other riders are out riding within reach. The group
  /// has not finished and this rider may need to be found.
  groupRiding,

  /// The leader has paused the group, so it is stopped on purpose.
  groupPaused,

  /// Following a route that is not yet finished.
  onRoute,

  /// A marker waiting for a group that is still expected.
  markerWaiting,

  /// None of the above: this rider is not riding with anyone or anything.
  dispersed,
}

/// The outcome of one evaluation.
@immutable
class DispersalAssessment {
  const DispersalAssessment(this.state);

  final DispersalState state;

  /// True only for [DispersalState.dispersed].
  bool get dispersed => state == DispersalState.dispersed;
}

/// Decides, at one instant, whether this rider has been left behind by the ride.
///
/// Pure: positions, freshness, route, marker and pause state in, a verdict out.
/// How long a verdict has held, and what to do about it, belong to
/// `LocationSharingGuard`.
///
/// The checks run strongest-evidence first, and the first that applies wins. A
/// rider is only [DispersalState.dispersed] when every one of them fails, which
/// is what keeps the rule from ever touching an actual ride:
///
///  1. **Solo ride** - there is no group.
///  2. **Unknown** - no position, or the group cannot be seen.
///  3. **With the group** - another rider within
///     [SharingDispersalPolicy.togetherRadiusMeters], seen within
///     [SharingDispersalPolicy.companyMemory].
///  4. **Group riding** - another rider *moving* within
///     [SharingDispersalPolicy.groupReachMeters], heard from in the last minute.
///  5. **Group paused** - the leader paused the group, up to a ceiling.
///  6. **On route** - on an unfinished route, unless parked on it for hours.
///  7. **Marker waiting** - a marker still waiting for a group, up to a ceiling.
DispersalAssessment assessDispersal(
  DispersalInput input, {
  SharingDispersalPolicy policy = const SharingDispersalPolicy(),
}) {
  if (!input.groupRide) {
    return const DispersalAssessment(DispersalState.soloRide);
  }
  final local = input.local;
  if (local == null || !input.peersObservable) {
    return const DispersalAssessment(DispersalState.unknown);
  }

  for (final peer in input.peers) {
    final position = peer.position;
    final age = peer.age;
    if (position == null || age == null || age > policy.companyMemory) {
      continue;
    }
    if (GeoCalculations.distanceMeters(local.position, position) <=
        policy.togetherRadiusMeters) {
      return const DispersalAssessment(DispersalState.withGroup);
    }
  }

  for (final peer in input.peers) {
    final position = peer.position;
    final speed = peer.speedMetersPerSecond;
    if (position == null ||
        speed == null ||
        !peer.isFresh ||
        speed < policy.movingSpeedMetersPerSecond) {
      continue;
    }
    if (GeoCalculations.distanceMeters(local.position, position) <=
        policy.groupReachMeters) {
      return const DispersalAssessment(DispersalState.groupRiding);
    }
  }

  final pausedAt = input.ridePausedAt;
  if (pausedAt != null &&
      input.now.difference(pausedAt) < policy.pauseAllowance) {
    return const DispersalAssessment(DispersalState.groupPaused);
  }

  final route = input.route;
  if (route != null &&
      route.withinCorridor &&
      route.progressFraction < policy.routeCompleteFraction &&
      input.localParkedFor < policy.routeStopAllowance) {
    return const DispersalAssessment(DispersalState.onRoute);
  }

  final marker = input.marker;
  if (marker != null &&
      !marker.tecPassed &&
      input.now.difference(marker.startedAt) < policy.markerWaitCeiling) {
    return const DispersalAssessment(DispersalState.markerWaiting);
  }

  return const DispersalAssessment(DispersalState.dispersed);
}

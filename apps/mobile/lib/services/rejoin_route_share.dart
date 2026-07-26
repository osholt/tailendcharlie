import 'dart:math' as math;

import '../domain/geo_point.dart';
import '../domain/ride_event.dart';
import 'ride_event_authenticator.dart';
import 'ride_lifecycle.dart';
import 'route_rejoin_planner.dart';

/// One rider's advisory rejoin route, as it travels to the ride leader.
///
/// #102 computes rejoin plans on the affected rider's own device and does not
/// relay them, because putting every rider's rejoin breadcrumb on every map is
/// exactly the clutter #125 and #133 are removing. This is the narrow exception:
/// the leader has a legitimate need to see where a separated rider is being
/// sent, so the plan is relayed **addressed to the leader** and to nobody else.
///
/// Privacy, stated plainly: the ride relay is ride-scoped, not per-recipient
/// encrypted, so "leader only" here means the same thing it means for an ICE
/// share ([RideEventType.iceInfoShared]) — the event names its intended
/// recipient, the sharer only sends when a leader is known, and every consumer
/// drops a share it is not addressed to. It is not a cryptographic guarantee
/// against another ride member who already holds the ride secret. Retention is
/// bounded the same way a location event is: a hard per-share TTL on the client
/// and a matching server-side retention cap.
class SharedRejoinRoute {
  const SharedRejoinRoute({
    required this.riderId,
    required this.displayName,
    required this.computedAt,
    required this.expiresAt,
    required this.routeRevisionNumber,
    this.severity = RouteRejoinSeverity.offRoute,
    this.status = RouteRejoinStatus.routed,
    this.target,
    this.breadcrumb = const [],
    this.rejoinPoint,
    this.distanceMeters,
    this.duration,
    this.requiresBacktracking = false,
    this.cleared = false,
  });

  final String riderId;
  final String displayName;
  final DateTime computedAt;

  /// When this share stops being shown, whatever else happens. A rejoin plan is
  /// perishable: it was computed for one position against one route.
  final DateTime expiresAt;

  /// The published route revision the plan was computed against. A share for a
  /// superseded revision is discarded rather than drawn against a route it was
  /// never computed for.
  final int routeRevisionNumber;

  final RouteRejoinSeverity severity;
  final RouteRejoinStatus status;
  final RouteRejoinTarget? target;
  final List<GeoPoint> breadcrumb;
  final GeoPoint? rejoinPoint;
  final double? distanceMeters;
  final Duration? duration;
  final bool requiresBacktracking;

  /// The expiry form: the rider is back on route, the route changed, or the
  /// ride ended. Carries no geometry.
  final bool cleared;

  bool get hasBreadcrumb => !cleared && breadcrumb.length >= 2;

  bool isLiveAt(DateTime now) => !cleared && now.isBefore(expiresAt);

  /// Leader-facing label for the breadcrumb on the map.
  String get mapLabel => switch (target) {
    RouteRejoinTarget.tailEndCharlie =>
      '$displayName rejoining, then on to Tail End Charlie',
    RouteRejoinTarget.leader => '$displayName rejoining, then on to you',
    RouteRejoinTarget.plannedRoute || null => '$displayName rejoin route',
  };

  Map<String, Object?> toJson() => {
    'riderId': riderId,
    'displayName': displayName,
    'computedAt': computedAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'routeRevision': routeRevisionNumber,
    if (cleared) 'cleared': true,
    if (!cleared) ...{
      'severity': severity.name,
      'status': status.name,
      if (target != null) 'target': target!.name,
      if (requiresBacktracking) 'requiresBacktracking': true,
      if (distanceMeters != null) 'distanceMeters': distanceMeters,
      if (duration != null) 'durationSeconds': duration!.inSeconds,
      if (rejoinPoint != null) 'rejoinPoint': _encodePoint(rejoinPoint!),
      if (breadcrumb.isNotEmpty)
        'breadcrumb': [for (final point in breadcrumb) _encodePoint(point)],
    },
  };

  /// Strict decode. Returns null rather than throwing, because one malformed
  /// share from a peer must never take the rest of a batch down with it.
  static SharedRejoinRoute? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final json = <String, Object?>{
      for (final entry in value.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
    final riderId = _string(json['riderId'], 128);
    final displayName = _string(json['displayName'], 80);
    final computedAt = _date(json['computedAt']);
    final expiresAt = _date(json['expiresAt']);
    final revision = json['routeRevision'];
    if (riderId == null ||
        displayName == null ||
        computedAt == null ||
        expiresAt == null ||
        revision is! int ||
        revision < 0) {
      return null;
    }
    if (json['cleared'] == true) {
      return SharedRejoinRoute(
        riderId: riderId,
        displayName: displayName,
        computedAt: computedAt,
        expiresAt: expiresAt,
        routeRevisionNumber: revision,
        cleared: true,
      );
    }
    final breadcrumb = _decodePoints(json['breadcrumb']);
    if (breadcrumb == null) return null;
    final duration = json['durationSeconds'];
    final distance = json['distanceMeters'];
    return SharedRejoinRoute(
      riderId: riderId,
      displayName: displayName,
      computedAt: computedAt,
      expiresAt: expiresAt,
      routeRevisionNumber: revision,
      severity:
          _enumByName(RouteRejoinSeverity.values, json['severity']) ??
          RouteRejoinSeverity.offRoute,
      status:
          _enumByName(RouteRejoinStatus.values, json['status']) ??
          RouteRejoinStatus.routed,
      target: _enumByName(RouteRejoinTarget.values, json['target']),
      breadcrumb: List.unmodifiable(breadcrumb),
      rejoinPoint: _decodePoint(json['rejoinPoint']),
      distanceMeters: distance is num ? distance.toDouble() : null,
      duration: duration is int && duration >= 0
          ? Duration(seconds: duration)
          : null,
      requiresBacktracking: json['requiresBacktracking'] == true,
    );
  }

  static List<Object?> _encodePoint(GeoPoint point) => [
    _round(point.latitude),
    _round(point.longitude),
  ];

  /// Five decimal places: about 1.1 m, far finer than the geometry a routing
  /// engine returns is worth, and it keeps a 60-point breadcrumb comfortably
  /// inside the 8 KiB per-event limit. It also shares one decimal fewer than a
  /// rider's own position sample, which is the point of a bounded share.
  static double _round(double value) =>
      (value * 100000).roundToDouble() / 100000;

  static GeoPoint? _decodePoint(Object? value) {
    if (value is! List || value.length != 2) return null;
    final latitude = value[0];
    final longitude = value[1];
    if (latitude is! num || longitude is! num) return null;
    if (latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      return null;
    }
    return GeoPoint(
      latitude: latitude.toDouble(),
      longitude: longitude.toDouble(),
    );
  }

  static List<GeoPoint>? _decodePoints(Object? value) {
    if (value == null) return const [];
    if (value is! List ||
        value.length > RejoinRouteRelayPolicy.absoluteMaximumBreadcrumbPoints) {
      return null;
    }
    final points = <GeoPoint>[];
    for (final item in value) {
      final point = _decodePoint(item);
      if (point == null) return null;
      points.add(point);
    }
    return points;
  }

  static T? _enumByName<T extends Enum>(List<T> values, Object? value) {
    if (value is! String) return null;
    for (final candidate in values) {
      if (candidate.name == value) return candidate;
    }
    return null;
  }

  static String? _string(Object? value, int maximumLength) {
    if (value is! String) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > maximumLength) return null;
    return trimmed;
  }

  static DateTime? _date(Object? value) {
    if (value is! String || value.length > 40) return null;
    try {
      return DateTime.parse(value).toLocal();
    } on FormatException {
      return null;
    }
  }
}

/// What the relay gate decided to do with the local rider's current plan.
enum RejoinRouteRelayAction { share, clear, skip }

class RejoinRouteRelayDecision {
  const RejoinRouteRelayDecision._(this.action, this.share, this.reason);

  const RejoinRouteRelayDecision.skip(String reason)
    : this._(RejoinRouteRelayAction.skip, null, reason);

  final RejoinRouteRelayAction action;
  final SharedRejoinRoute? share;

  /// Why, in a fixed vocabulary. Only ever used for tests and diagnostics.
  final String reason;
}

/// How often a rejoin plan may be **relayed**, independently of how often it is
/// recomputed locally.
///
/// #102 recomputes under a 45 s floor plus a 250 m rider-movement or 400 m
/// target-movement gate. Relaying every recomputation would be a significant
/// new event volume on exactly the ride where riders are already separated and
/// possibly on poor coverage, so the relayed form has its own, slower bound:
///
/// * **One share per rider per [minimumInterval] (120 s). No exceptions** — not
///   for a severity escalation, not for a changed target. The leader already
///   learns that a rider is off course, and how badly, from the existing
///   unthrottled `routeDeviationChanged` alert; this event carries only the
///   rejoin *geometry*, and geometry two minutes old still answers "which way
///   have they gone". Delaying the breadcrumb costs the leader nothing safety
///   critical, so it is the right thing to bound.
/// * **A clear is immediate and exempt.** An expiry has to be prompt: a
///   breadcrumb that outlives the situation is a lie about where a rider is
///   heading. A clear can only follow a share, so it cannot be a volume risk.
/// * **A share expires [shareLifetime] (10 min) after it was computed**, and
///   is discarded on sight once the route revision it was computed against is
///   superseded.
///
/// Worst case, the case from the field report — a rider circling off route for
/// ten minutes: at most six shares plus one clear, about 20 KB in total. That
/// is measured in `rejoin_route_share_test.dart` rather than asserted by eye.
class RejoinRouteRelayPolicy {
  const RejoinRouteRelayPolicy({
    this.minimumInterval = const Duration(minutes: 2),
    this.shareLifetime = const Duration(minutes: 10),
    this.maximumBreadcrumbPoints = 60,
  }) : assert(maximumBreadcrumbPoints >= 2),
       assert(maximumBreadcrumbPoints <= absoluteMaximumBreadcrumbPoints);

  /// The hard ceiling a decoder enforces on a peer's breadcrumb, well inside
  /// the event schema's 128-entry collection limit and its 8 KiB size limit.
  static const absoluteMaximumBreadcrumbPoints = 96;

  final Duration minimumInterval;
  final Duration shareLifetime;
  final int maximumBreadcrumbPoints;

  /// Evenly resamples a breadcrumb down to [maximumBreadcrumbPoints], always
  /// keeping the first and last point so the line still starts at the rider and
  /// ends at the rejoin. Never invents geometry: every kept point came from the
  /// routing engine.
  List<GeoPoint> boundBreadcrumb(List<GeoPoint> points) {
    if (points.length <= maximumBreadcrumbPoints) {
      return List.unmodifiable(points);
    }
    final kept = <GeoPoint>[];
    final step = (points.length - 1) / (maximumBreadcrumbPoints - 1);
    for (var index = 0; index < maximumBreadcrumbPoints - 1; index += 1) {
      kept.add(points[(index * step).round()]);
    }
    kept.add(points.last);
    return List.unmodifiable(kept);
  }
}

/// Decides when the local rider's rejoin plan is relayed to the leader.
///
/// One instance per ride. Holds only what the bound needs: the last share it
/// emitted and when.
class RejoinRouteRelayGate {
  RejoinRouteRelayGate({this.policy = const RejoinRouteRelayPolicy()});

  final RejoinRouteRelayPolicy policy;

  SharedRejoinRoute? _lastShared;
  DateTime? _lastSharedAt;

  /// Shares emitted since the gate was created, for the bounding tests.
  int get sharedCount => _sharedCount;
  int _sharedCount = 0;

  int get clearedCount => _clearedCount;
  int _clearedCount = 0;

  SharedRejoinRoute? get lastShared => _lastShared;

  void reset() {
    _lastShared = null;
    _lastSharedAt = null;
  }

  /// [plan] is the local rider's current plan, or null when there is none.
  /// [routeRevisionNumber] is the published route revision it was computed
  /// against. [rideEnded] forces the clear branch.
  RejoinRouteRelayDecision evaluate({
    required RouteRejoinPlan? plan,
    required String displayName,
    required int routeRevisionNumber,
    required DateTime now,
    bool rideEnded = false,
  }) {
    final previous = _lastShared;
    final needsClear =
        rideEnded ||
        plan == null ||
        !plan.hasBreadcrumb ||
        plan.severity == RouteRejoinSeverity.onRoute;
    if (needsClear) {
      if (previous == null) {
        return const RejoinRouteRelayDecision.skip('nothing-shared');
      }
      return _clear(previous, now: now, displayName: displayName);
    }
    // A share computed against a superseded route is worthless to the leader:
    // clear it and let the next plan start fresh against the new route.
    if (previous != null &&
        previous.routeRevisionNumber != routeRevisionNumber) {
      return _clear(previous, now: now, displayName: displayName);
    }
    final lastSharedAt = _lastSharedAt;
    if (lastSharedAt != null &&
        now.difference(lastSharedAt) < policy.minimumInterval) {
      return const RejoinRouteRelayDecision.skip('rate-limited');
    }
    final share = SharedRejoinRoute(
      riderId: plan.riderId,
      displayName: displayName,
      computedAt: plan.computedAt,
      expiresAt: plan.computedAt.add(policy.shareLifetime),
      routeRevisionNumber: routeRevisionNumber,
      severity: plan.severity,
      status: plan.status,
      target: plan.target,
      breadcrumb: policy.boundBreadcrumb(plan.breadcrumb),
      rejoinPoint: plan.rejoinPoint,
      distanceMeters: plan.distanceMeters,
      duration: plan.duration,
      requiresBacktracking: plan.requiresBacktracking,
    );
    _lastShared = share;
    _lastSharedAt = now;
    _sharedCount += 1;
    return RejoinRouteRelayDecision._(
      RejoinRouteRelayAction.share,
      share,
      'shared',
    );
  }

  RejoinRouteRelayDecision _clear(
    SharedRejoinRoute previous, {
    required DateTime now,
    required String displayName,
  }) {
    final clear = SharedRejoinRoute(
      riderId: previous.riderId,
      displayName: displayName,
      computedAt: now,
      // A clear is a tombstone, not a plan: it only has to outlive the share it
      // retires, so it carries the share's own expiry as its floor.
      expiresAt: _laterOf(now, previous.expiresAt),
      routeRevisionNumber: previous.routeRevisionNumber,
      cleared: true,
    );
    _lastShared = null;
    _lastSharedAt = null;
    _clearedCount += 1;
    return RejoinRouteRelayDecision._(
      RejoinRouteRelayAction.clear,
      clear,
      'cleared',
    );
  }

  static DateTime _laterOf(DateTime left, DateTime right) =>
      left.isAfter(right) ? left : right;
}

/// Rebuilds the rejoin routes shared **with the local rider** from the journal.
///
/// Every filter here is a rule from #128 part 2, applied in one place so the
/// map, the roster and any companion surface cannot disagree:
///
/// * addressed to the local rider, so a share is not group-visible;
/// * authored by the rider it describes, so nobody can plant a breadcrumb on
///   another rider's behalf;
/// * for the current route revision, so a plan never draws against a route it
///   was not computed for;
/// * inside its own TTL;
/// * not cleared, and not from a rider who has left the ride.
class SharedRejoinRouteReducer {
  const SharedRejoinRouteReducer();

  Map<String, SharedRejoinRoute> fromEvents({
    required String rideId,
    required String inviteSecret,
    required Iterable<RideEvent> events,
    required String localRiderId,
    required int routeRevisionNumber,
    required DateTime now,
    Iterable<String> departedRiderIds = const [],
    bool rideEnded = false,
  }) {
    if (rideEnded) return const {};
    final ordered =
        events
            .where(
              (event) =>
                  event.rideId == rideId &&
                  event.type == RideEventType.rejoinRouteShared &&
                  RideEventAuthenticator.verify(event, inviteSecret),
            )
            .toList(growable: false)
          ..sort(RideLifecycleReducer.compareEvents);
    final departed = departedRiderIds.toSet();
    final latest = <String, SharedRejoinRoute>{};
    for (final event in ordered) {
      if (!_isAddressedTo(event, localRiderId)) continue;
      final share = SharedRejoinRoute.tryFromJson(event.payload['share']);
      // Only the affected rider may publish their own rejoin route.
      if (share == null || share.riderId != event.deviceId) continue;
      // The leader's own plan is already on their map from #102; relaying it
      // back to themselves would draw it twice.
      if (share.riderId == localRiderId) continue;
      latest[share.riderId] = share;
    }
    return Map.unmodifiable({
      for (final entry in latest.entries)
        if (!departed.contains(entry.key) &&
            entry.value.isLiveAt(now) &&
            entry.value.routeRevisionNumber == routeRevisionNumber &&
            entry.value.hasBreadcrumb)
          entry.key: entry.value,
    });
  }

  /// Builds the payload a rider records. The recipient list is what makes this
  /// leader-addressed rather than group-visible; it follows the existing
  /// `statusMessage` and `iceInfoShared` convention exactly.
  static Map<String, Object?> payload({
    required SharedRejoinRoute share,
    required String leaderRiderId,
  }) => {
    'share': share.toJson(),
    'recipientRiderIds': [leaderRiderId],
  };

  static bool _isAddressedTo(RideEvent event, String riderId) {
    final recipients = event.payload['recipientRiderIds'];
    // Deliberately fails closed: a share with no recipient list is not treated
    // as group-visible, it is ignored.
    if (recipients is! List) return false;
    return recipients.contains(riderId);
  }
}

/// The measured worst case from the field report, so the bound in
/// [RejoinRouteRelayPolicy] is a number and not a claim.
int maximumRejoinSharesOver(
  Duration excursion, {
  RejoinRouteRelayPolicy policy = const RejoinRouteRelayPolicy(),
}) =>
    1 +
    math.max(
      0,
      excursion.inMilliseconds ~/ policy.minimumInterval.inMilliseconds,
    );

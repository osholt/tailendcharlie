import '../domain/ride_role.dart';
import '../domain/rider_color.dart';
import '../domain/rider_location.dart';
import '../features/map/motorcycle_icon.dart';

/// How old a rider's newest position is, in states a rider can act on.
///
/// Thresholds are deliberately explicit and shared by every surface so a map
/// marker, the roster and a vehicle head unit cannot disagree about whether a
/// position is trustworthy. A [stale] position is still retained so it can be
/// visibly demoted rather than silently disappearing, which is the difference
/// between "I can see he has stopped reporting" and "he vanished".
enum PresenceFreshness {
  /// Reported within [PresenceFreshnessPolicy.liveWithin].
  live,

  /// Older than [PresenceFreshnessPolicy.liveWithin] but still within
  /// [PresenceFreshnessPolicy.ageingWithin].
  ageing,

  /// Older than [PresenceFreshnessPolicy.ageingWithin].
  ///
  /// Still drawn: where a rider stopped is exactly what the group needs in
  /// order to go back for them. It is demoted in wording and colour so it can
  /// never be mistaken for a current position.
  stale,

  /// No position at all — the rider is in the ride but nothing has arrived.
  none,
}

extension PresenceFreshnessLabels on PresenceFreshness {
  /// Wording that never relies on colour alone.
  String get label => switch (this) {
    PresenceFreshness.live => 'Live',
    PresenceFreshness.ageing => 'Ageing',
    PresenceFreshness.stale => 'Stale',
    PresenceFreshness.none => 'No position',
  };

  bool get isTrustworthy => this == PresenceFreshness.live;

  /// True when the position is recent enough to count as current proof that the
  /// rider is reachable. A stale position is evidence of a past fix only.
  bool get isTrackedAsContact =>
      this == PresenceFreshness.live || this == PresenceFreshness.ageing;
}

/// The documented age thresholds for [PresenceFreshness].
class PresenceFreshnessPolicy {
  const PresenceFreshnessPolicy({
    this.liveWithin = const Duration(seconds: 20),
    this.ageingWithin = const Duration(seconds: 60),
    this.retainFor = const Duration(minutes: 5),
  });

  /// A position at most this old is [PresenceFreshness.live].
  final Duration liveWithin;

  /// A position at most this old is [PresenceFreshness.ageing]; anything older
  /// is [PresenceFreshness.stale].
  final Duration ageingWithin;

  /// How long the *ephemeral* presence channels keep reporting a snapshot after
  /// it stops being refreshed.
  ///
  /// This bounds an in-memory cache; it is not a rule for hiding positions. A
  /// stale position is demoted, never deleted — deleting it would turn "he
  /// stopped moving here" into "he was never here", which is the failure this
  /// whole model exists to remove.
  final Duration retainFor;

  PresenceFreshness classify(Duration age) {
    final bounded = age.isNegative ? Duration.zero : age;
    if (bounded <= liveWithin) return PresenceFreshness.live;
    if (bounded <= ageingWithin) return PresenceFreshness.ageing;
    return PresenceFreshness.stale;
  }
}

/// Which channel produced a position. A rider can be corroborated by more than
/// one at a time; that is evidence of reachability, not a conflict.
enum LivePresenceSource {
  /// This phone's own GPS.
  localDevice,

  /// The ephemeral, non-journalled presence channel over the internet relay.
  internetPresence,

  /// The ephemeral, non-journalled presence channel over the nearby relay.
  nearbyPresence,

  /// A durable `riderLocationUpdated` event from the offline-first journal.
  journal,
}

extension LivePresenceSourceLabels on LivePresenceSource {
  String get label => switch (this) {
    LivePresenceSource.localDevice => 'This phone',
    LivePresenceSource.internetPresence => 'Internet presence',
    LivePresenceSource.nearbyPresence => 'Nearby presence',
    LivePresenceSource.journal => 'Ride journal',
  };
}

/// A rider the transport says is in the ride, learned without waiting for the
/// bulk event batch.
///
/// This is advisory: the durable journal stays authoritative for identity and
/// role. A roster member exists so a wedged or backed-off batch sync cannot
/// hide a participant who is demonstrably reachable.
class PresenceRosterMember {
  const PresenceRosterMember({
    required this.riderId,
    required this.displayName,
    required this.role,
    required this.joinedAt,
    this.left = false,
    this.motorcycleStyle = motorcycleIconStyleDefault,
    this.riderColor = riderColorDefault,
  });

  final String riderId;
  final String displayName;
  final RideRole role;
  final DateTime joinedAt;
  final bool left;
  final MotorcycleIconStyle motorcycleStyle;
  final RiderColor riderColor;
}

/// One rider's reconciled live state, spanning both ride phases and every
/// transport.
class LiveRiderPresence {
  const LiveRiderPresence({
    required this.riderId,
    required this.displayName,
    required this.role,
    required this.freshness,
    required this.sources,
    required this.isLocal,
    required this.knownSince,
    this.motorcycleStyle = motorcycleIconStyleDefault,
    this.riderColor = riderColorDefault,
    this.location,
    this.age,
  });

  final String riderId;
  final String displayName;
  final RideRole role;
  final PresenceFreshness freshness;
  final Set<LivePresenceSource> sources;
  final bool isLocal;

  /// The earliest moment this rider is known to have been in the ride, from the
  /// roster when the transport supplies it and otherwise from their oldest
  /// observed sample. Deterministic so a recomputed roster does not reorder.
  final DateTime knownSince;
  final MotorcycleIconStyle motorcycleStyle;
  final RiderColor riderColor;

  /// The newest position for this rider, or null when there is none worth
  /// drawing. Never a position older than
  /// [PresenceFreshnessPolicy.retainFor].
  final RiderLocation? location;

  /// Age of [location] at the moment of reconciliation.
  final Duration? age;

  bool get hasPosition => location != null;

  /// Plain wording for a roster row or marker label. Never colour-only.
  String get freshnessLabel {
    final currentAge = age;
    if (freshness == PresenceFreshness.none || currentAge == null) {
      return PresenceFreshness.none.label;
    }
    if (freshness == PresenceFreshness.live) {
      return PresenceFreshness.live.label;
    }
    return '${freshness.label} ${formatPresenceAge(currentAge)}';
  }
}

/// Compact, human age used in marker labels and roster rows.
String formatPresenceAge(Duration age) {
  final seconds = age.isNegative ? 0 : age.inSeconds;
  if (seconds < 60) return '${seconds}s';
  final minutes = age.inMinutes;
  if (minutes < 60) return '${minutes}m';
  return '${age.inHours}h';
}

/// Every reason live rider state can be incomplete, as a named state rather
/// than an empty map.
enum PresenceLimitationKind {
  /// The configured ride service does not advertise the presence capability.
  serviceCapabilityMissing,

  /// The ride service is reachable but presence requests are failing.
  serviceUnreachable,

  /// The ride credential was rejected for presence.
  serviceUnauthorized,

  /// This app is older than the ride service requires.
  clientUpdateRequired,

  /// The ride service is older than this app.
  serviceUpgradeRequired,

  /// A peer's app is too old to publish continuous live positions.
  peerAppOlder,

  /// Events this app does not understand arrived and were ignored.
  unsupportedEventsIgnored,

  /// Events could not be uploaded because the service lacks the capability.
  uploadCapabilityMissing,

  /// An event the service refuses was set aside so the rest of the ride keeps
  /// flowing.
  uploadQuarantined,

  /// The ride service cannot carry a leader-issued Tail End Charlie request, so
  /// the role has to be taken by the rider themselves.
  tecAssignmentUnsupportedByService,

  /// A named rider's app cannot read a leader-issued Tail End Charlie request.
  tecAssignmentUnsupportedByPeer,

  /// The ride service cannot carry a rider's rejoin route to the leader.
  rejoinSharingUnsupportedByService,
}

/// A single named, user-readable limitation.
///
/// [message] is composed from a fixed vocabulary. It never carries a hostname,
/// URL, credential or raw error text.
class PresenceLimitation {
  const PresenceLimitation({
    required this.kind,
    required this.message,
    this.riderId,
    this.riderDisplayName,
  });

  final PresenceLimitationKind kind;
  final String message;
  final String? riderId;
  final String? riderDisplayName;

  static PresenceLimitation peerAppOlder({
    required String riderId,
    required String displayName,
  }) => PresenceLimitation(
    kind: PresenceLimitationKind.peerAppOlder,
    riderId: riderId,
    riderDisplayName: displayName,
    message:
        "$displayName's app is older — their live position will not appear "
        'once the ride starts until they update.',
  );

  static const serviceCapabilityMissing = PresenceLimitation(
    kind: PresenceLimitationKind.serviceCapabilityMissing,
    message:
        'The ride service does not support live rider positions yet, so only '
        'saved ride history is shared.',
  );

  static const serviceUnreachable = PresenceLimitation(
    kind: PresenceLimitationKind.serviceUnreachable,
    message:
        'Live rider positions are paused because the ride service cannot be '
        'reached. They resume automatically.',
  );

  static const serviceUnauthorized = PresenceLimitation(
    kind: PresenceLimitationKind.serviceUnauthorized,
    message:
        'The ride service rejected this ride invitation, so live rider '
        'positions are unavailable. Re-join with a fresh invite.',
  );

  static const clientUpdateRequired = PresenceLimitation(
    kind: PresenceLimitationKind.clientUpdateRequired,
    message:
        'Update Tail End Charlie: this build is older than the ride service '
        'supports, so live rider positions are unavailable.',
  );

  static const serviceUpgradeRequired = PresenceLimitation(
    kind: PresenceLimitationKind.serviceUpgradeRequired,
    message:
        'This app is newer than the ride service, so live rider positions are '
        'unavailable until the service is updated.',
  );

  static PresenceLimitation unsupportedEventsIgnored(int count) =>
      PresenceLimitation(
        kind: PresenceLimitationKind.unsupportedEventsIgnored,
        message:
            '$count ride update${count == 1 ? '' : 's'} from a newer app '
            'version could not be read and were skipped. Everything else in '
            'the ride is unaffected.',
      );

  static PresenceLimitation uploadCapabilityMissing(int count) =>
      PresenceLimitation(
        kind: PresenceLimitationKind.uploadCapabilityMissing,
        message:
            '$count ride update${count == 1 ? '' : 's'} stayed on this phone '
            'because the ride service does not support them yet.',
      );

  static PresenceLimitation uploadQuarantined(int count) => PresenceLimitation(
    kind: PresenceLimitationKind.uploadQuarantined,
    message:
        '$count ride update${count == 1 ? '' : 's'} were set aside because the '
        'ride service refused them. Joining, positions and alerts keep working.',
  );

  /// The outgoing direction for #128 part 1: this build can ask, the relay
  /// cannot carry the question. Names the fallback rather than letting the
  /// leader believe a rider was asked.
  static const tecAssignmentUnsupportedByService = PresenceLimitation(
    kind: PresenceLimitationKind.tecAssignmentUnsupportedByService,
    message:
        'The ride service is too old to pass on a Tail End Charlie request, so '
        'nobody has been asked. The rider has to set the role themselves on '
        'their own Ride tab.',
  );

  /// The incoming direction for #128 part 1: the request will reach that
  /// rider's phone and their build will skip it, so the leader must be told
  /// which rider, by name, rather than watching a request sit at "waiting".
  static PresenceLimitation tecAssignmentUnsupportedByPeer({
    required String riderId,
    required String displayName,
  }) => PresenceLimitation(
    kind: PresenceLimitationKind.tecAssignmentUnsupportedByPeer,
    riderId: riderId,
    riderDisplayName: displayName,
    message:
        "$displayName's app is older — they will not see a Tail End Charlie "
        'request until they update. Ask them to set the role themselves.',
  );

  /// #128 part 2. The rider keeps their own rejoin guidance either way; only the
  /// leader's copy is lost, and the leader is told so.
  static const rejoinSharingUnsupportedByService = PresenceLimitation(
    kind: PresenceLimitationKind.rejoinSharingUnsupportedByService,
    message:
        'The ride service is too old to send your rejoin route to the ride '
        'leader. You still have it on this phone; the leader will not see it.',
  );
}

/// Merges every position channel into one per-rider live state.
///
/// The reconciler is pure and phase-neutral on purpose. Pre-start presence,
/// post-start journal events and nearby presence all arrive here, so a rider
/// visible before the start stays visible across `rideStarted` without
/// re-opting-in and without a duplicate identity.
class LivePresenceReconciler {
  const LivePresenceReconciler({this.policy = const PresenceFreshnessPolicy()});

  final PresenceFreshnessPolicy policy;

  /// [journal] is the durable post-start location history, [internetPresence]
  /// and [nearbyPresence] are the ephemeral channels, and [roster] names riders
  /// the transport has seen even when no position exists yet.
  List<LiveRiderPresence> reconcile({
    required DateTime now,
    required String localRiderId,
    Iterable<RiderLocation> journal = const [],
    Iterable<RiderLocation> internetPresence = const [],
    Iterable<RiderLocation> nearbyPresence = const [],
    Iterable<PresenceRosterMember> roster = const [],
  }) {
    final best = <String, _Candidate>{};
    void offer(RiderLocation location, LivePresenceSource source) {
      final existing = best[location.riderId];
      if (existing == null) {
        best[location.riderId] = _Candidate(location, {source});
        return;
      }
      existing.sources.add(source);
      if (location.sample.recordedAt.isBefore(existing.oldestSampleAt)) {
        existing.oldestSampleAt = location.sample.recordedAt;
      }
      // Newest recorded sample wins, so a duplicate or out-of-order delivery
      // can never rewind a rider to an older coordinate.
      if (location.sample.recordedAt.isAfter(
        existing.location.sample.recordedAt,
      )) {
        existing.location = location;
      }
    }

    for (final location in journal) {
      offer(location, LivePresenceSource.journal);
    }
    for (final location in internetPresence) {
      offer(location, LivePresenceSource.internetPresence);
    }
    for (final location in nearbyPresence) {
      offer(location, LivePresenceSource.nearbyPresence);
    }

    final rosterById = <String, PresenceRosterMember>{};
    final departed = <String>{};
    for (final member in roster) {
      if (member.left) {
        departed.add(member.riderId);
        continue;
      }
      rosterById[member.riderId] = member;
    }

    final result = <LiveRiderPresence>[];
    for (final riderId in {...best.keys, ...rosterById.keys}) {
      // A departure is explicit and authoritative. A lingering ephemeral
      // position must not resurrect a rider who has left the ride.
      if (departed.contains(riderId)) continue;
      final candidate = best[riderId];
      final member = rosterById[riderId];
      final isLocal = riderId == localRiderId;
      if (candidate == null) {
        result.add(
          LiveRiderPresence(
            riderId: riderId,
            displayName: member!.displayName,
            role: member.role,
            freshness: PresenceFreshness.none,
            sources: const {},
            isLocal: isLocal,
            knownSince: member.joinedAt,
            motorcycleStyle: member.motorcycleStyle,
            riderColor: member.riderColor,
          ),
        );
        continue;
      }
      final location = candidate.location;
      final age = location.sample.ageAt(now);
      final freshness = policy.classify(age);
      final sources = {
        ...candidate.sources,
        if (isLocal) LivePresenceSource.localDevice,
      };
      result.add(
        LiveRiderPresence(
          riderId: riderId,
          // The roster is the transport's authoritative identity when it has
          // one; a position payload is only self-described.
          displayName: member?.displayName ?? location.displayName,
          role: member?.role ?? location.role,
          freshness: freshness,
          sources: Set.unmodifiable(sources),
          isLocal: isLocal,
          knownSince: member?.joinedAt ?? candidate.oldestSampleAt,
          motorcycleStyle: location.motorcycleStyle,
          riderColor: location.riderColor,
          location: location,
          age: age,
        ),
      );
    }
    result.sort((left, right) {
      final byName = left.displayName.compareTo(right.displayName);
      return byName != 0 ? byName : left.riderId.compareTo(right.riderId);
    });
    return List.unmodifiable(result);
  }

  /// The reconciled positions worth drawing, newest per rider.
  List<RiderLocation> reconcileLocations({
    required DateTime now,
    required String localRiderId,
    Iterable<RiderLocation> journal = const [],
    Iterable<RiderLocation> internetPresence = const [],
    Iterable<RiderLocation> nearbyPresence = const [],
  }) => List.unmodifiable([
    for (final presence in reconcile(
      now: now,
      localRiderId: localRiderId,
      journal: journal,
      internetPresence: internetPresence,
      nearbyPresence: nearbyPresence,
    ))
      ?presence.location,
  ]);
}

class _Candidate {
  _Candidate(this.location, this.sources)
    : oldestSampleAt = location.sample.recordedAt;

  RiderLocation location;
  final Set<LivePresenceSource> sources;
  DateTime oldestSampleAt;
}

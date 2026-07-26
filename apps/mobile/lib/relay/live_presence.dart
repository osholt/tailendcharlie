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

/// Which clock a position's age was measured on.
///
/// Two phones do not share a clock, so ageing a peer's position by this
/// device's clock minus the *peer's* own timestamp measures the difference
/// between two clocks as well as the age. A relay-stamped arrival time and the
/// relay's own current time are one clock, so they can be subtracted honestly.
enum PresenceClockBasis {
  /// Aged on the relay's clock: its arrival stamp against its current time.
  sharedRelayClock,

  /// Aged on this device's clock against the publisher's own timestamp. Correct
  /// for this phone's own fixes; for a peer it is only as good as their clock.
  publisherClock,
}

extension PresenceClockBasisLabels on PresenceClockBasis {
  String get label => switch (this) {
    PresenceClockBasis.sharedRelayClock => 'Timed by the ride service',
    PresenceClockBasis.publisherClock => "Timed by the rider's own phone",
  };
}

/// The documented age thresholds for [PresenceFreshness].
class PresenceFreshnessPolicy {
  const PresenceFreshnessPolicy({
    this.liveWithin = const Duration(seconds: 20),
    this.ageingWithin = const Duration(seconds: 60),
    this.retainFor = const Duration(minutes: 5),
    this.publisherClockTolerance = const Duration(seconds: 30),
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

  /// How far a publisher's own timestamp may sit from the relay's arrival stamp
  /// before that phone's clock is treated as untrustworthy rather than its
  /// position as old. Beyond this the disagreement is stated in words; it never
  /// ages a reporting rider out silently.
  final Duration publisherClockTolerance;

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
    this.leftAt,
    this.motorcycleStyle = motorcycleIconStyleDefault,
    this.riderColor = riderColorDefault,
  });

  final String riderId;
  final String displayName;
  final RideRole role;
  final DateTime joinedAt;
  final bool left;

  /// When the relay recorded this rider's departure, when it reports it.
  ///
  /// Null from a relay that does not, in which case the departure is still
  /// authoritative but cannot be ordered against a later rejoin, so the roster
  /// may only add a departed row it alone knows about (#144).
  final DateTime? leftAt;
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
    this.clockBasis = PresenceClockBasis.publisherClock,
    this.publisherClockOffset,
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

  /// Which clock [age] was measured on.
  final PresenceClockBasis clockBasis;

  /// How far the publisher's own timestamp sits behind the relay's arrival stamp
  /// for [location], when the relay stamped it. Positive means the publisher's
  /// phone clock is behind the relay's.
  ///
  /// This is the difference between two clocks, not an age. It exists so a
  /// rider whose clock is wrong is *told* that, instead of being aged out as if
  /// they had stopped reporting.
  final Duration? publisherClockOffset;

  /// True when the publisher's clock disagrees with the relay's by more than the
  /// policy tolerates, so their own timestamps cannot be used to judge freshness.
  bool get publisherClockUntrusted => publisherClockOffset != null;

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

  /// A peer's phone clock disagrees with the ride service, so their own
  /// timestamps cannot be used to judge how fresh their position is.
  riderClockUntrusted,

  /// Live positions arrived but could not be read, so they were skipped rather
  /// than discarding the whole reply.
  positionsUnreadable,

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

  /// Names a peer whose phone clock disagrees with the ride service.
  ///
  /// Their position is still shown and still counts as contact: it is timed by
  /// the ride service instead of by their phone. Saying so is the alternative to
  /// silently ageing out a rider who is reporting perfectly well.
  static PresenceLimitation riderClockUntrusted({
    required String riderId,
    required String displayName,
    required Duration offset,
  }) => PresenceLimitation(
    kind: PresenceLimitationKind.riderClockUntrusted,
    riderId: riderId,
    riderDisplayName: displayName,
    message:
        "$displayName's phone clock is ${formatPresenceAge(offset.abs())} "
        '${offset.isNegative ? 'ahead of' : 'behind'} the ride service, so '
        'their position is timed by the ride service instead. Their location '
        'is still live.',
  );

  static PresenceLimitation positionsUnreadable(
    int count,
  ) => PresenceLimitation(
    kind: PresenceLimitationKind.positionsUnreadable,
    message:
        '$count live position${count == 1 ? '' : 's'} could not be read and '
        'were skipped. Every other rider is unaffected.',
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
  ///
  /// [relayClockOffset] is the relay's clock minus this device's, measured on the
  /// last successful presence sync. A remote rider's position that the relay
  /// stamped is aged on the relay's clock — the only clock both phones share —
  /// so a peer whose own clock is wrong is never aged out as if they had stopped
  /// reporting. This device's own fixes are always aged on its own clock.
  List<LiveRiderPresence> reconcile({
    required DateTime now,
    required String localRiderId,
    Iterable<RiderLocation> journal = const [],
    Iterable<RiderLocation> internetPresence = const [],
    Iterable<RiderLocation> nearbyPresence = const [],
    Iterable<PresenceRosterMember> roster = const [],
    Duration relayClockOffset = Duration.zero,
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
        existing.newestSource = source;
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
      // A remote position the relay stamped is aged on the relay's clock: its
      // arrival stamp against the relay's current time. Both come from one
      // clock, so the subtraction is an age and nothing else. This device's own
      // fixes never travel through the relay before being drawn, so they stay on
      // this device's clock.
      final relayStamped =
          !isLocal &&
          candidate.newestSource == LivePresenceSource.internetPresence;
      final publisherOffset = location.receivedAt.difference(
        location.sample.recordedAt,
      );
      final age = relayStamped
          ? _nonNegative(
              now.add(relayClockOffset).difference(location.receivedAt),
            )
          : location.sample.ageAt(now);
      final freshness = policy.classify(age);
      final sources = {
        ...candidate.sources,
        if (isLocal) LivePresenceSource.localDevice,
      };
      result.add(
        LiveRiderPresence(
          clockBasis: relayStamped
              ? PresenceClockBasis.sharedRelayClock
              : PresenceClockBasis.publisherClock,
          publisherClockOffset:
              relayStamped &&
                  publisherOffset.abs() > policy.publisherClockTolerance
              ? publisherOffset
              : null,
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
    Duration relayClockOffset = Duration.zero,
  }) => List.unmodifiable([
    for (final presence in reconcile(
      now: now,
      localRiderId: localRiderId,
      journal: journal,
      internetPresence: internetPresence,
      nearbyPresence: nearbyPresence,
      relayClockOffset: relayClockOffset,
    ))
      ?presence.location,
  ]);
}

Duration _nonNegative(Duration value) =>
    value.isNegative ? Duration.zero : value;

class _Candidate {
  _Candidate(this.location, this.sources)
    : oldestSampleAt = location.sample.recordedAt,
      newestSource = sources.first;

  RiderLocation location;
  final Set<LivePresenceSource> sources;
  DateTime oldestSampleAt;

  /// Which channel supplied [location]. Only the internet presence channel
  /// carries a relay-stamped arrival time.
  LivePresenceSource newestSource;
}

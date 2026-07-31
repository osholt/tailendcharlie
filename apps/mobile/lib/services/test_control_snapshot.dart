import '../controllers/ride_controller.dart';
import '../controllers/situational_awareness_controller.dart';
import '../domain/hazard.dart';
import '../relay/live_presence.dart';
import 'ride_membership.dart';

/// The state a driven field-test asserts against.
///
/// The design point of this file is that it reports the roster and live presence
/// as **two independent derivations**, and then states where they disagree.
///
/// That is deliberate. `RideController.participants` comes from
/// `RideMembershipReducer` over the event journal;
/// `SituationalAwarenessController.livePresenceAt` comes from the presence
/// channel. Issue #132 was exactly a divergence between them - the leader
/// counted the follower in the roster and simultaneously showed them inactive
/// with no position. A snapshot that reported one merged view would have looked
/// perfectly healthy while that bug was live, and would have been worthless.
///
/// So [TestControlSnapshot.reconcile] does not smooth the two together. It
/// reports both and names the riders each side accounts for differently, which is
/// the measurement step 8b of `docs/field-test-plan.md` actually calls for:
/// "the rider count equals the number of drawn markers plus the riders whose row
/// states why they have no position. There is no rider in the count with
/// neither."
///
/// Nothing here carries the ride's invite secret, join token, phone numbers or
/// emergency-contact data. A snapshot is meant to be safe to paste into a test
/// log; capability material is a separate, explicit read.
class TestControlSnapshot {
  const TestControlSnapshot._(this._payload);

  final Map<String, Object?> _payload;

  Map<String, Object?> toJson() => _payload;

  /// [awareness] is null between rides. That is an ordinary state, not an error:
  /// the roster still reports whatever the journal holds, and presence is empty
  /// because there is no ride generating it.
  static TestControlSnapshot capture({
    required RideController ride,
    required SituationalAwarenessController? awareness,
    required DateTime now,
  }) {
    final session = ride.session;
    final participants = ride.participants;
    final presence = awareness?.livePresenceAt(now) ?? const [];

    return TestControlSnapshot._({
      'capturedAt': now.toUtc().toIso8601String(),
      'ride': session == null
          ? null
          : {
              'rideId': session.rideId,
              'rideCode': session.rideCode,
              'localRiderId': session.localRiderId,
              'displayName': session.displayName,
              'role': session.role.name,
              // No inviteSecret, no joinToken - see the class comment.
            },
      'roster': [
        for (final participant in participants)
          _participantJson(participant, now),
      ],
      'presence': [for (final rider in presence) _presenceJson(rider, now)],
      // Sub-step 3 of step 8b measures how long a hazard takes to travel from one
      // idle phone to another, so the receiving phone must be able to say whether
      // it has arrived yet. Without this the delay is not measurable at all: an
      // earlier driver script tried to infer arrival from the presence count,
      // which never changes when a hazard lands, and so reported an instant
      // delivery every single time.
      'hazards': [
        for (final hazard in awareness?.activeHazards ?? const <HazardReport>[])
          {
            'id': hazard.id,
            'type': hazard.type.name,
            'severity': hazard.severity.name,
            'reporterId': hazard.reporterId,
            'source': hazard.source.name,
            'reportedAt': hazard.reportedAt.toUtc().toIso8601String(),
            'ageSeconds': now.difference(hazard.reportedAt).inSeconds,
          },
      ],
      'reconciliation': reconcile(participants, presence),
    });
  }

  static Map<String, Object?> _participantJson(
    RideParticipant participant,
    DateTime now,
  ) => {
    'riderId': participant.riderId,
    'displayName': participant.displayName,
    'role': participant.role.name,
    'state': participant.state.name,
    'isLocal': participant.isLocal,
    'hasLastKnownLocation': participant.lastKnownLocation != null,
    'secondsSinceLastSeen': now.difference(participant.lastSeenAt).inSeconds,
    'hasLeft': participant.leftAt != null,
  };

  static Map<String, Object?> _presenceJson(
    LiveRiderPresence rider,
    DateTime now,
  ) => {
    'riderId': rider.riderId,
    'displayName': rider.displayName,
    'role': rider.role.name,
    'freshness': rider.freshness.name,
    'isLocal': rider.isLocal,
    'hasPosition': rider.location != null,
    'sources': [for (final source in rider.sources) source.name],
    // The clock-skew case in step 8b sub-step 5. A peer whose clock is wrong
    // must still read as live, with the offset named rather than inferred from
    // a rider silently going missing.
    'clockBasis': rider.clockBasis.name,
    'publisherClockOffsetSeconds': rider.publisherClockOffset?.inSeconds,
    'ageSeconds': rider.age?.inSeconds,
  };

  /// Where the two derivations disagree.
  ///
  /// [countedWithoutPositionOrReason] is the #132 signature and the one that
  /// fails the pass gate: a rider present in the roster who has neither a
  /// position nor a presence entry explaining the absence. An empty list is the
  /// passing state.
  ///
  /// `awaitingFirstFix` is deliberately **not** part of that failure, and the
  /// distinction was found by driving a real ride rather than by reasoning. At
  /// ride start every rider is in the roster and nobody has reported a position
  /// yet, so an earlier version of this method reported the leader as counted
  /// without a reason and failed the gate on a healthy ride. An automated run
  /// would then have manufactured evidence of a #132 recurrence that was not
  /// there - the precise failure this whole surface is supposed to avoid.
  ///
  /// The discriminator is [RideParticipant.lastKnownLocation]. A rider who has
  /// **never** reported a position is starting up; a rider who *has* reported one
  /// and has since vanished from the presence channel with no explanation is the
  /// real fault.
  static Map<String, Object?> reconcile(
    List<RideParticipant> participants,
    List<LiveRiderPresence> presence,
  ) {
    final presenceById = {for (final rider in presence) rider.riderId: rider};
    final placed = <String>[];
    final explained = <String>[];
    final awaitingFirstFix = <String>[];
    final unaccounted = <String>[];

    for (final participant in participants) {
      if (participant.leftAt != null) continue;
      final rider = presenceById[participant.riderId];
      if (rider?.location != null) {
        placed.add(participant.riderId);
      } else if (rider != null) {
        // Present in the presence channel with no position: the row can state
        // why - stale, ageing, no fix yet. That satisfies the gate.
        explained.add(participant.riderId);
      } else if (participant.lastKnownLocation == null) {
        // Never reported a position, so there is nothing to have lost. Normal
        // between joining and the first fix.
        awaitingFirstFix.add(participant.riderId);
      } else {
        unaccounted.add(participant.riderId);
      }
    }

    final rosterIds = {
      for (final participant in participants)
        if (participant.leftAt == null) participant.riderId,
    };

    return {
      'rosterCount': rosterIds.length,
      'presenceCount': presence.length,
      'withPosition': placed,
      'withoutPositionButExplained': explained,
      // Reported separately so a driver can see the startup state without it
      // being mistaken for a fault. Does not fail the gate.
      'awaitingFirstFix': awaitingFirstFix,
      'countedWithoutPositionOrReason': unaccounted,
      // Present in presence but absent from the roster: the mirror-image fault,
      // which would draw a marker for somebody the roster does not admit to.
      'placedButNotInRoster': [
        for (final rider in presence)
          if (!rosterIds.contains(rider.riderId)) rider.riderId,
      ],
      'gateSatisfied':
          unaccounted.isEmpty &&
          presence.every((rider) => rosterIds.contains(rider.riderId)),
    };
  }
}

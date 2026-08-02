import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_color.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/features/map/motorcycle_icon.dart';
import 'package:ride_relay/relay/live_presence.dart';
import 'package:ride_relay/services/ride_membership.dart';

/// **From what moment is a rider's position visible to the rest of the group?**
///
/// Decided for #300: **from the moment they join.** Before setting off is
/// exactly when a group is working out who has arrived and where they are, so
/// a map with no people on it is the map being useless when it is most looked
/// at.
///
/// The rule has two halves and they are deliberately carried by different
/// channels:
///
///  - **Presence makes a rider visible.** Ephemeral, current position only, and
///    it runs across the `rideStarted` transition, so a rider gathering at the
///    meet point appears and stays visible when the ride begins.
///  - **The journal records history, and history starts at Start ride.** No
///    track point is written or transmitted before then; a rider who joins an
///    hour early and rides elsewhere first leaves no trace of it.
///    `situational_awareness_controller_test.dart` holds that half.
///
/// This existed as behaviour before it existed as a rule, which is why the
/// original report read as a bug. Written down here so a future change has to
/// disagree with it on purpose.
void main() {
  final now = DateTime.utc(2026, 8, 2, 9);

  RiderLocation locationFor(String riderId, {DateTime? at}) => RiderLocation(
    riderId: riderId,
    displayName: riderId,
    role: RideRole.rider,
    sample: LocationSample(
      position: const GeoPoint(latitude: 51.4676, longitude: -2.5015),
      recordedAt: at ?? now,
      accuracyMeters: 5,
    ),
    receivedAt: at ?? now,
  );

  PresenceRosterMember rosterMember(String riderId) => PresenceRosterMember(
    riderId: riderId,
    displayName: riderId,
    role: RideRole.rider,
    joinedAt: now,
  );

  RideParticipant participant(
    String riderId, {
    RideMembershipState state = RideMembershipState.joined,
  }) => RideParticipant(
    riderId: riderId,
    displayName: riderId,
    role: RideRole.rider,
    joinedAt: now,
    lastSeenAt: now,
    state: state,
    motorcycleStyle: MotorcycleIconStyle.adventureTourer,
    riderSymbol: riderSymbolDefault,
    riderColor: RiderColor.green,
    transportEvidence: const {RideTransportEvidence.internetRelay},
    isLocal: false,
  );

  /// The production render path for a real (non-simulated) ride: presence is
  /// reconciled across its sources, then the live view decides who is drawn.
  /// `active_ride_shell.dart` hands the result straight to the map.
  RideLiveView render({
    required List<RiderLocation> presencePositions,
    required List<RideParticipant> participants,
  }) => RideLiveView.reconcile(
    participants: participants,
    presence: const LivePresenceReconciler().reconcile(
      now: now,
      localRiderId: 'me',
      // Deliberately empty: before the ride starts the journal has nothing in
      // it, and that is the point. Everything drawn here comes from presence.
      journal: const [],
      internetPresence: presencePositions,
      roster: [for (final rider in participants) rosterMember(rider.riderId)],
    ),
  );

  test('a rider who has joined is drawn before the ride starts', () {
    final view = render(
      presencePositions: [locationFor('sam')],
      participants: [participant('sam')],
    );

    expect(view.renderedPositions.map((location) => location.riderId), ['sam']);
  });

  test('every rider in the pre-start count either has a position or a '
      'stated reason for not having one', () {
    // The invariant `RideLiveView` was built for (#132), which has to hold
    // before the start too or the pre-start map can count someone it refuses
    // to draw, with nothing said.
    final view = render(
      presencePositions: [locationFor('sam')],
      participants: [participant('sam'), participant('alex')],
    );

    expect(view.participants, hasLength(2));
    expect(
      view.participants.every((rider) => rider.hasStatedPositionState),
      isTrue,
    );
    final alex = view.participants.firstWhere(
      (rider) => rider.riderId == 'alex',
    );
    expect(alex.positionAbsence, RidePositionAbsence.noPositionReported);
  });

  test('a rider who has left is not drawn, whenever they left', () {
    // A departure is authoritative in both phases. A lingering ephemeral
    // position must not resurrect someone who has gone home.
    final view = render(
      presencePositions: [locationFor('sam')],
      participants: [participant('sam', state: RideMembershipState.left)],
    );

    expect(view.renderedPositions, isEmpty);
  });

  test('visibility does not wait for a route', () {
    // The original report was made with no GPX set. Nothing in this path reads
    // a route, and that is what the test is here to keep true (#124).
    final view = render(
      presencePositions: [locationFor('sam'), locationFor('alex')],
      participants: [participant('sam'), participant('alex')],
    );

    expect(view.renderedPositions, hasLength(2));
  });

  test('the same riders stay drawn once the ride starts', () {
    // Presence runs across the transition on purpose. Nobody may blink out at
    // the moment the leader presses Start.
    final before = render(
      presencePositions: [locationFor('sam')],
      participants: [participant('sam')],
    );
    final after = render(
      presencePositions: [
        locationFor('sam', at: now.add(const Duration(seconds: 30))),
      ],
      participants: [participant('sam', state: RideMembershipState.active)],
    );

    expect(
      after.renderedPositions.map((location) => location.riderId),
      before.renderedPositions.map((location) => location.riderId),
    );
  });
}

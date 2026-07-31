import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_color.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/features/map/motorcycle_icon.dart';
import 'package:ride_relay/relay/live_presence.dart';
import 'package:ride_relay/services/ride_membership.dart';
import 'package:ride_relay/services/test_control_snapshot.dart';

/// `ride_live_view_test.dart` asserts the app's own roster/marker agreement for
/// issue #132. These tests assert that the **driven** surface reports that same
/// disagreement instead of hiding it.
///
/// This matters because the whole value of automating step 8b is that the machine
/// notices what a tired person at a bench would not. A snapshot that merged the
/// roster and the presence channel into one tidy list would have reported a
/// healthy ride throughout the #132 field failure, and the automation would have
/// been worse than useless - it would have manufactured false evidence.
void main() {
  final now = DateTime.utc(2026, 7, 31, 12);

  test('a rider with a position is reported as placed, and the gate holds', () {
    final result = TestControlSnapshot.reconcile(
      [_participant('r1'), _participant('r2')],
      [
        _presence('r1', location: _location('r1', now)),
        _presence('r2', location: _location('r2', now)),
      ],
    );

    expect(result['rosterCount'], 2);
    expect(result['withPosition'], ['r1', 'r2']);
    expect(result['countedWithoutPositionOrReason'], isEmpty);
    expect(result['gateSatisfied'], isTrue);
  });

  test('a rider with no position but a presence row still satisfies the '
      'gate', () {
    // A stale or not-yet-fixed rider is fine: their row can say why. The pass
    // gate is about riders with neither a position nor a reason.
    final result = TestControlSnapshot.reconcile(
      [_participant('r1'), _participant('r2')],
      [
        _presence('r1', location: _location('r1', now)),
        _presence('r2', freshness: PresenceFreshness.stale),
      ],
    );

    expect(result['withPosition'], ['r1']);
    expect(result['withoutPositionButExplained'], ['r2']);
    expect(result['countedWithoutPositionOrReason'], isEmpty);
    expect(result['gateSatisfied'], isTrue);
  });

  test('the #132 signature is reported, not smoothed away', () {
    // The exact field failure: the roster counts two riders, the presence
    // channel knows about one. The second rider is counted with no position and
    // no row to explain it.
    final result = TestControlSnapshot.reconcile(
      [
        _participant('r1'),
        // Has reported a position before, so its absence from the presence
        // channel is a loss rather than a startup state.
        _participant(
          'r2',
          state: RideMembershipState.inactive,
          lastKnownLocation: _location('r2', now),
        ),
      ],
      [_presence('r1', location: _location('r1', now))],
    );

    expect(result['rosterCount'], 2);
    expect(result['presenceCount'], 1);
    expect(
      result['countedWithoutPositionOrReason'],
      ['r2'],
      reason: 'the counted-but-unplaced rider must be named',
    );
    expect(
      result['gateSatisfied'],
      isFalse,
      reason: 'a driven test must fail here, not report a healthy ride',
    );
  });

  test('the mirror-image fault is reported too', () {
    // A marker drawn for somebody the roster does not admit to. Less commonly
    // seen than #132 but the same class of divergence, and a driven run should
    // not have to notice it by eye.
    final result = TestControlSnapshot.reconcile(
      [_participant('r1')],
      [
        _presence('r1', location: _location('r1', now)),
        _presence('ghost', location: _location('ghost', now)),
      ],
    );

    expect(result['placedButNotInRoster'], ['ghost']);
    expect(result['gateSatisfied'], isFalse);
  });

  test('a departed rider is excluded from the count rather than counted '
      'without a position', () {
    // #144: a rider who has left stays in the roster until the ride ends, but
    // must not be counted as a live rider with no position - that would look
    // exactly like the #132 fault and send a driven test hunting a bug that is
    // not there.
    final result = TestControlSnapshot.reconcile(
      [
        _participant('r1'),
        _participant(
          'r2',
          leftAt: now,
          lastKnownLocation: _location('r2', now),
        ),
      ],
      [_presence('r1', location: _location('r1', now))],
    );

    expect(result['rosterCount'], 1);
    expect(result['countedWithoutPositionOrReason'], isEmpty);
    expect(result['gateSatisfied'], isTrue);
  });

  test('a rider who has never had a fix is starting up, not a fault', () {
    // Found by driving a real ride: at /v1/ride/start the leader is in the
    // roster, the presence channel is empty and nobody has reported a position
    // yet. An earlier version failed the gate here, which would have reported a
    // #132 recurrence on a completely healthy ride.
    final result = TestControlSnapshot.reconcile([
      _participant('r1'),
    ], const []);

    expect(result['rosterCount'], 1);
    expect(result['awaitingFirstFix'], ['r1']);
    expect(result['countedWithoutPositionOrReason'], isEmpty);
    expect(
      result['gateSatisfied'],
      isTrue,
      reason: 'ride start must not read as a bug',
    );
  });
}

RideParticipant _participant(
  String riderId, {
  RideMembershipState state = RideMembershipState.active,
  DateTime? leftAt,
  RiderLocation? lastKnownLocation,
}) => RideParticipant(
  lastKnownLocation: lastKnownLocation,
  riderId: riderId,
  displayName: riderId.toUpperCase(),
  role: RideRole.rider,
  joinedAt: DateTime.utc(2026, 7, 31, 11),
  lastSeenAt: DateTime.utc(2026, 7, 31, 11, 59),
  leftAt: leftAt,
  state: state,
  motorcycleStyle: motorcycleIconStyleDefault,
  riderColor: riderColorDefault,
  transportEvidence: const {RideTransportEvidence.internetRelay},
  isLocal: false,
);

LiveRiderPresence _presence(
  String riderId, {
  RiderLocation? location,
  PresenceFreshness freshness = PresenceFreshness.live,
}) => LiveRiderPresence(
  riderId: riderId,
  displayName: riderId.toUpperCase(),
  role: RideRole.rider,
  freshness: location == null ? freshness : PresenceFreshness.live,
  sources: const {LivePresenceSource.internetPresence},
  isLocal: false,
  knownSince: DateTime.utc(2026, 7, 31, 11),
  location: location,
);

RiderLocation _location(String riderId, DateTime at) => RiderLocation(
  riderId: riderId,
  displayName: riderId.toUpperCase(),
  role: RideRole.rider,
  sample: LocationSample(
    position: const GeoPoint(latitude: 51.2, longitude: -2.4),
    recordedAt: at,
    accuracyMeters: 5,
  ),
  receivedAt: at,
);

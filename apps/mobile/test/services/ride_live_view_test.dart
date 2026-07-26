import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/rider_color.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/features/map/motorcycle_icon.dart';
import 'package:ride_relay/relay/live_presence.dart';
import 'package:ride_relay/services/ride_membership.dart';

/// Issue #132: the rider count and the drawn markers were two separate
/// judgements of the same rider, so a leader could count a follower ("2 riders")
/// and simultaneously show them inactive with no position and no explanation.
///
/// These tests assert the agreement itself: for one rider set, the live count is
/// exactly the riders with a rendered position plus the riders with a stated
/// reason for having none. Nothing may fall between the two.
void main() {
  final now = DateTime.utc(2026, 7, 26, 12);

  test('every counted rider is either rendered or stated, never neither', () {
    final view = RideLiveView.reconcile(
      participants: [
        _participant('leader', 'Lead', role: RideRole.lead),
        _participant('follower', 'Alex'),
        _participant('sam', 'Sam'),
      ],
      presence: [
        _presence('leader', 'Lead', location: _location('leader', 'Lead', now)),
        _presence(
          'follower',
          'Alex',
          location: _location('follower', 'Alex', now),
        ),
        // Named by the roster, no position yet.
        _presence('sam', 'Sam'),
      ],
    );

    expect(view.liveRiderCount, 3);
    expect(view.renderedPositions.map((position) => position.riderId), [
      'leader',
      'follower',
    ]);
    expect(view.countedWithoutPosition.map((entry) => entry.riderId), ['sam']);
    expect(view.isReconciled, isTrue);
    for (final entry in view.countedWithoutPosition) {
      expect(entry.positionAbsence.label, isNotNull);
      expect(entry.hasStatedPositionState, isTrue);
    }
  });

  test('the field failure: counted, no marker, and a reason on the row', () {
    // The leader counts two riders and has no position for the follower. That
    // is allowed only while the reason is on the roster row.
    final view = RideLiveView.reconcile(
      participants: [
        _participant('leader', 'Lead', role: RideRole.lead),
        _participant('follower', 'Alex', state: RideMembershipState.inactive),
      ],
      presence: [
        _presence('leader', 'Lead', location: _location('leader', 'Lead', now)),
      ],
    );

    expect(view.liveRiderCount, 2);
    expect(view.renderedPositions.length, 1);
    final follower = view.countedWithoutPosition.single;
    expect(follower.riderId, 'follower');
    expect(follower.positionAbsence, RidePositionAbsence.noPositionReported);
    expect(follower.stateLabel, contains('no position reported yet'));
    expect(view.isReconciled, isTrue);
  });

  test(
    'a transport that cannot deliver positions is blamed, not the rider',
    () {
      final view = RideLiveView.reconcile(
        participants: [
          _participant('leader', 'Lead', role: RideRole.lead),
          _participant('follower', 'Alex'),
        ],
        presence: const [],
        positionChannelUnavailable: true,
      );

      expect(view.liveRiderCount, 2);
      expect(view.renderedPositions, isEmpty);
      expect(
        view.countedWithoutPosition.map((entry) => entry.positionAbsence),
        everyElement(RidePositionAbsence.positionChannelUnavailable),
      );
      expect(
        view.countedWithoutPosition.first.stateLabel,
        contains('live positions paused on this phone'),
      );
    },
  );

  test('a rider who has left is neither counted nor rendered', () {
    final view = RideLiveView.reconcile(
      participants: [
        _participant('leader', 'Lead', role: RideRole.lead),
        _participant('gone', 'Gone', state: RideMembershipState.left),
      ],
      presence: [
        _presence('leader', 'Lead', location: _location('leader', 'Lead', now)),
        // A lingering ephemeral position for a rider who has left.
        _presence('gone', 'Gone', location: _location('gone', 'Gone', now)),
      ],
    );

    expect(view.liveRiderCount, 1);
    expect(view.renderedPositions.single.riderId, 'leader');
    expect(view.countedWithoutPosition, isEmpty);
    expect(view.isReconciled, isTrue);
  });

  test('the record a departed rider keeps is never drawn as a marker', () {
    // Issue #144 keeps the roster row and its last known position. That record
    // is readable and it is not a marker: the rider is not there.
    final view = RideLiveView.reconcile(
      participants: [
        _participant('leader', 'Lead', role: RideRole.lead),
        _participant(
          'gone',
          'Gone',
          state: RideMembershipState.left,
          lastKnownLocation: _location(
            'gone',
            'Gone',
            now.subtract(const Duration(minutes: 8)),
          ),
        ),
      ],
      presence: [
        _presence('leader', 'Lead', location: _location('leader', 'Lead', now)),
      ],
    );

    expect(view.liveRiderCount, 1);
    expect(view.renderedPositions.map((position) => position.riderId), [
      'leader',
    ]);
    expect(view.countedWithoutPosition, isEmpty);
    expect(view.isReconciled, isTrue);
    final gone = view.participants.singleWhere(
      (participant) => participant.riderId == 'gone',
    );
    expect(gone.lastKnownPositionLabel, contains('51.20000, -2.40000'));
    expect(gone.isEligibleForLivePosition, isFalse);
    expect(gone.hasStatedPositionState, isTrue);
  });

  test('a stale position is still rendered, and still counted', () {
    final view = RideLiveView.reconcile(
      participants: [
        _participant('leader', 'Lead', role: RideRole.lead),
        _participant('follower', 'Alex', state: RideMembershipState.inactive),
      ],
      presence: [
        _presence('leader', 'Lead', location: _location('leader', 'Lead', now)),
        _presence(
          'follower',
          'Alex',
          freshness: PresenceFreshness.stale,
          location: _location(
            'follower',
            'Alex',
            now.subtract(const Duration(minutes: 3)),
          ),
        ),
      ],
    );

    expect(view.liveRiderCount, 2);
    expect(view.renderedPositions.length, 2);
    expect(view.countedWithoutPosition, isEmpty);
    expect(view.isReconciled, isTrue);
  });
}

RideParticipant _participant(
  String riderId,
  String displayName, {
  RideRole role = RideRole.rider,
  RideMembershipState state = RideMembershipState.active,
  RiderLocation? lastKnownLocation,
}) => RideParticipant(
  lastKnownLocation: lastKnownLocation,
  riderId: riderId,
  displayName: displayName,
  role: role,
  joinedAt: DateTime.utc(2026, 7, 26, 11),
  lastSeenAt: DateTime.utc(2026, 7, 26, 12),
  state: state,
  motorcycleStyle: motorcycleIconStyleDefault,
  riderColor: riderColorDefault,
  transportEvidence: const {RideTransportEvidence.internetRelay},
  isLocal: false,
);

LiveRiderPresence _presence(
  String riderId,
  String displayName, {
  RiderLocation? location,
  PresenceFreshness freshness = PresenceFreshness.live,
}) => LiveRiderPresence(
  riderId: riderId,
  displayName: displayName,
  role: RideRole.rider,
  freshness: location == null ? PresenceFreshness.none : freshness,
  sources: const {LivePresenceSource.internetPresence},
  isLocal: false,
  knownSince: DateTime.utc(2026, 7, 26, 11),
  location: location,
);

RiderLocation _location(String riderId, String displayName, DateTime at) =>
    RiderLocation(
      riderId: riderId,
      displayName: displayName,
      role: RideRole.rider,
      sample: LocationSample(
        position: const GeoPoint(latitude: 51.2, longitude: -2.4),
        recordedAt: at,
        accuracyMeters: 5,
      ),
      receivedAt: at,
    );

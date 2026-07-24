import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/features/ride/active_ride_shell.dart';

void main() {
  test('observer snapshot uses only the local device GPS sample', () {
    final now = DateTime.utc(2026, 7, 24, 12);
    final session = RideSession(
      rideId: 'private-ride-id',
      rideCode: '123456',
      inviteSecret: 'private-invite-secret-012345',
      joinToken: 'private-join-token',
      localRiderId: 'local-rider',
      displayName: 'Local rider',
      role: RideRole.rider,
      joinedAt: now,
    );
    final local = LocationSample(
      position: const GeoPoint(latitude: 51.5, longitude: -0.1),
      recordedAt: now,
      accuracyMeters: 5,
    );

    final snapshot = buildLocalObserverSnapshot(
      session: session,
      snapshotGeneratedAt: now,
      rideStatus: 'waiting',
      statusUpdatedAt: now,
      assistanceUpdatedAt: now,
      localLocation: local,
      assistance: null,
    );
    final encoded = snapshot.toJson().toString();

    expect(snapshot.subjectName, 'Local rider');
    expect(snapshot.position?.latitude, 51.5);
    expect(encoded, isNot(contains('private-ride-id')));
    expect(encoded, isNot(contains('private-invite-secret')));
    expect(encoded, isNot(contains('local-rider')));
  });

  test('a forged relay status for the local rider is never observer input', () {
    final now = DateTime.utc(2026, 7, 24, 12);
    final forgedRemoteEvent = RideEvent(
      id: 'remote-forgery',
      rideId: 'ride-a',
      deviceId: 'local-rider',
      type: RideEventType.statusMessage,
      priority: EventPriority.critical,
      createdAt: now,
      payload: const {'message': 'emergencyStop'},
      signature: 'a' * 64,
    );
    final session = RideSession(
      rideId: 'ride-a',
      rideCode: '123456',
      inviteSecret: 'private-invite-secret-012345',
      joinToken: 'private-join-token',
      localRiderId: 'local-rider',
      displayName: 'Local rider',
      role: RideRole.rider,
      joinedAt: now,
    );

    expect(forgedRemoteEvent.payload['message'], 'emergencyStop');
    final snapshot = buildLocalObserverSnapshot(
      session: session,
      snapshotGeneratedAt: now,
      rideStatus: 'active',
      statusUpdatedAt: now,
      assistanceUpdatedAt: session.joinedAt,
      localLocation: null,
      // Only installation-local send/resolve actions may populate this value;
      // shared journal events are deliberately not an input.
      assistance: null,
    );

    expect(snapshot.assistance, isNull);
  });
}

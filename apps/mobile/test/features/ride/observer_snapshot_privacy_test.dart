import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/features/ride/active_ride_shell.dart';
import 'package:ride_relay/services/rejoin_route_share.dart';
import 'package:ride_relay/services/rider_contact_share.dart';

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

  test('a rejoin route shared with the leader never reaches an observer', () {
    // Issue #128 part 2 shares a rider's intended path with the ride leader.
    // Issue #36 observers are a separate authorisation decision, so the observer
    // snapshot must carry no route geometry at all - not the planned route, not
    // a rejoin breadcrumb, not a rejoin point.
    final now = DateTime.utc(2026, 7, 26, 12);
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
    final rejoin = SharedRejoinRoute(
      riderId: 'local-rider',
      displayName: 'Local rider',
      computedAt: now,
      expiresAt: now.add(const Duration(minutes: 10)),
      routeRevisionNumber: 1,
      breadcrumb: const [
        GeoPoint(latitude: 52.9876, longitude: -1.2345),
        GeoPoint(latitude: 52.9886, longitude: -1.2355),
      ],
      rejoinPoint: const GeoPoint(latitude: 52.99, longitude: -1.24),
    );

    final snapshot = buildLocalObserverSnapshot(
      session: session,
      snapshotGeneratedAt: now,
      rideStatus: 'active',
      statusUpdatedAt: now,
      assistanceUpdatedAt: now,
      localLocation: LocationSample(
        position: const GeoPoint(latitude: 51.5, longitude: -0.1),
        recordedAt: now,
        accuracyMeters: 5,
      ),
      assistance: null,
    );
    final encoded = snapshot.toJson().toString();

    // Only the last known position, which the rider consented to separately.
    expect(snapshot.position?.latitude, 51.5);
    expect(encoded, isNot(contains('52.98')));
    expect(encoded, isNot(contains('breadcrumb')));
    expect(encoded, isNot(contains('rejoin')));
    // The share itself does carry the path - to the leader, and only there.
    expect(rejoin.toJson().toString(), contains('52.98'));
    // The snapshot builder takes no rejoin input at all, so there is no field
    // for a future change to populate by accident.
    expect(snapshot.toJson().keys, isNot(contains('rejoinRoute')));
  });

  test('a phone number shared inside the ride never reaches an observer', () {
    // Issue #188 lets a rider give their own number to the ride's coordination
    // roles. An observer link is a separate authorisation decision (#36), so it
    // gets nothing of the sort - the same rule ICE has always had.
    final now = DateTime.utc(2026, 7, 27, 12);
    final session = RideSession(
      rideId: 'private-ride-id',
      rideCode: '123456',
      inviteSecret: 'private-invite-secret-012345',
      joinToken: 'private-join-token',
      localRiderId: 'local-rider',
      displayName: 'Local rider',
      role: RideRole.lead,
      joinedAt: now,
    );
    const sharedNumber = '+44 7700 900321';
    final contact = RiderContactShare(
      eventId: 'contact-share',
      riderId: 'bill',
      displayName: 'Bill',
      phoneNumber: sharedNumber,
      sharedAt: now,
      sharedByRole: RideRole.rider,
      toRideGroup: false,
    );

    final snapshot = buildLocalObserverSnapshot(
      session: session,
      snapshotGeneratedAt: now,
      rideStatus: 'active',
      statusUpdatedAt: now,
      assistanceUpdatedAt: now,
      localLocation: LocationSample(
        position: const GeoPoint(latitude: 51.5, longitude: -0.1),
        recordedAt: now,
        accuracyMeters: 5,
      ),
      assistance: null,
    );
    final encoded = snapshot.toJson().toString();

    expect(encoded, isNot(contains(sharedNumber)));
    expect(encoded, isNot(contains('900321')));
    expect(encoded, isNot(contains('phone')));
    expect(encoded, isNot(contains('contact')));
    // The share itself does carry the number - to the recipients it names.
    expect(contact.toJson()['phone'], sharedNumber);
    // And there is no snapshot field for a later change to populate.
    expect(snapshot.toJson().keys, isNot(contains('phoneNumber')));
    expect(snapshot.toJson().keys, isNot(contains('riderContact')));
  });
}

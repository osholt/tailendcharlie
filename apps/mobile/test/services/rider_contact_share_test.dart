import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';
import 'package:ride_relay/services/rider_contact_share.dart';

/// Issue #188. A rider's **own** number reaches the people who might have to
/// ring them, and nobody else; it is never mistaken for the ICE contact; and it
/// is gone from a recipient's phone once the ride is over.
void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  const rideId = 'ride-188';
  final sharedAt = DateTime.utc(2026, 7, 27, 11);

  RideEvent share({
    String id = 'share-1',
    String deviceId = 'bill',
    String riderId = 'bill',
    String displayName = 'Bill',
    String phone = '+44 7700 900321',
    RideRole role = RideRole.rider,
    DateTime? createdAt,
    List<String>? recipientRiderIds = const ['leader'],
    String rideIdOverride = rideId,
    bool signed = true,
  }) {
    final unsigned = RideEvent(
      id: id,
      rideId: rideIdOverride,
      deviceId: deviceId,
      type: RideEventType.riderContactShared,
      priority: EventPriority.important,
      createdAt: createdAt ?? sharedAt,
      payload: {
        'contact': {
          'riderId': riderId,
          'displayName': displayName,
          'phone': phone,
          'sharedByRole': role.name,
        },
        'recipientRiderIds': ?recipientRiderIds,
      },
      signature: '',
    );
    return RideEvent(
      id: unsigned.id,
      rideId: unsigned.rideId,
      deviceId: unsigned.deviceId,
      type: unsigned.type,
      priority: unsigned.priority,
      createdAt: unsigned.createdAt,
      payload: unsigned.payload,
      signature: signed
          ? RideEventAuthenticator.sign(unsigned, secret)
          : 'f' * 64,
    );
  }

  Map<String, RiderContactShare> reduce(
    List<RideEvent> events, {
    String localRiderId = 'leader',
    DateTime? now,
    Iterable<String> departedRiderIds = const [],
    bool rideEnded = false,
  }) => const RiderContactShareReducer().fromEvents(
    rideId: rideId,
    inviteSecret: secret,
    events: events,
    localRiderId: localRiderId,
    now: now ?? sharedAt.add(const Duration(minutes: 1)),
    departedRiderIds: departedRiderIds,
    rideEnded: rideEnded,
  );

  group('who a number reaches', () {
    test('an addressed share reaches its recipient', () {
      final result = reduce([
        share(recipientRiderIds: const ['leader', 'tec']),
      ]);

      expect(result.keys, ['bill']);
      expect(result['bill']!.phoneNumber, '+44 7700 900321');
      expect(result['bill']!.displayName, 'Bill');
      expect(result['bill']!.toRideGroup, isFalse);
    });

    test("a non-recipient's journal holds the event but never the "
        'number', () {
      final events = [
        share(recipientRiderIds: const ['leader', 'tec']),
      ];

      // The relay is ride-scoped, so an ordinary rider's phone can receive the
      // event. What must never happen is the number becoming *available* to
      // them: the one reducer every surface reads yields nothing at all.
      expect(reduce(events, localRiderId: 'ordinary-rider'), isEmpty);
      expect(reduce(events, localRiderId: 'another-rider'), isEmpty);
      expect(reduce(events, localRiderId: 'tec').keys, ['bill']);
    });

    test('a coordination role publishes to the ride, so a stopped rider can '
        'reach them', () {
      // The case in the original request: a rider who has stopped needs the
      // leader's number, and a contact for the role is useless addressed only
      // to the other role-holder.
      final result = reduce([
        share(
          deviceId: 'leader',
          riderId: 'leader',
          displayName: 'Oliver',
          role: RideRole.lead,
          recipientRiderIds: null,
        ),
      ], localRiderId: 'ordinary-rider');

      expect(result['leader']!.toRideGroup, isTrue);
      expect(result['leader']!.sharedByRole, RideRole.lead);
    });

    test('a malformed recipient list fails closed rather than reading as '
        'ride-wide', () {
      final malformed = RideEvent(
        id: 'malformed',
        rideId: rideId,
        deviceId: 'bill',
        type: RideEventType.riderContactShared,
        priority: EventPriority.important,
        createdAt: sharedAt,
        payload: const {
          'contact': {
            'riderId': 'bill',
            'displayName': 'Bill',
            'phone': '+44 7700 900321',
          },
          'recipientRiderIds': 'leader',
        },
        signature: '',
      );
      final signed = RideEvent(
        id: malformed.id,
        rideId: malformed.rideId,
        deviceId: malformed.deviceId,
        type: malformed.type,
        priority: malformed.priority,
        createdAt: malformed.createdAt,
        payload: malformed.payload,
        signature: RideEventAuthenticator.sign(malformed, secret),
      );

      expect(reduce([signed]), isEmpty);
      expect(RiderContactShareReducer.isAddressedTo(signed, 'leader'), isFalse);
    });
  });

  group('what the reducer refuses', () {
    test('an unsigned or forged event', () {
      expect(reduce([share(signed: false)]), isEmpty);
    });

    test('a number planted on another rider', () {
      expect(reduce([share(deviceId: 'mallory', riderId: 'bill')]), isEmpty);
    });

    test("the local rider's own share, so nobody is offered a control to "
        'ring themselves', () {
      expect(
        reduce([
          share(deviceId: 'leader', riderId: 'leader'),
        ], localRiderId: 'leader'),
        isEmpty,
      );
    });

    test('a share from a rider who has left', () {
      expect(reduce([share()], departedRiderIds: const ['bill']), isEmpty);
    });

    test('a share past its lifetime, on the client as well as the '
        'relay', () {
      expect(
        reduce([share()], now: sharedAt.add(riderContactShareLifetime)),
        isEmpty,
      );
      expect(
        reduce(
          [share()],
          now: sharedAt.add(
            riderContactShareLifetime - const Duration(minutes: 1),
          ),
        ),
        isNotEmpty,
      );
    });

    test('every share once the ride has ended', () {
      expect(reduce([share()], rideEnded: true), isEmpty);
    });

    test('an event from another ride', () {
      expect(reduce([share(rideIdOverride: 'someone-elses-ride')]), isEmpty);
    });

    test('a number the phone cannot dial', () {
      for (final rejected in [
        'tel:+447700900321',
        '+44 7700 900321?body=hi',
        'ring me on the mobile',
        '',
        '12',
        'sms:07700900321',
        '+44 7700 900321\nx',
      ]) {
        expect(reduce([share(phone: rejected)]), isEmpty, reason: rejected);
      }
    });

    test('the latest share per rider wins', () {
      final result = reduce([
        share(id: 'old', phone: '+44 7700 900111'),
        share(
          id: 'new',
          phone: '+44 7700 900222',
          createdAt: sharedAt.add(const Duration(seconds: 30)),
        ),
      ]);

      expect(result['bill']!.phoneNumber, '+44 7700 900222');
      expect(result['bill']!.eventId, 'new');
    });
  });

  group('the recipient rule', () {
    test('an ordinary rider addresses the leader and TEC, and nobody '
        'else', () {
      final recipients = RiderContactRecipients.resolve(
        localRole: RideRole.rider,
        leaderRiderId: 'leader',
        tecRiderIds: const ['tec-a', 'tec-b'],
      );

      expect(recipients.toRideGroup, isFalse);
      expect(recipients.riderIds, ['leader', 'tec-a', 'tec-b']);
      expect(recipients.isEmpty, isFalse);
    });

    test('a rider with no leader and no TEC has nobody to share with', () {
      final recipients = RiderContactRecipients.resolve(
        localRole: RideRole.rider,
        leaderRiderId: null,
        tecRiderIds: const [],
      );

      expect(recipients.isEmpty, isTrue);
    });

    for (final role in [RideRole.lead, RideRole.tailEndCharlie]) {
      test('a ${role.name} offers theirs to the ride', () {
        final recipients = RiderContactRecipients.resolve(
          localRole: role,
          leaderRiderId: null,
          tecRiderIds: const [],
        );

        expect(recipients.toRideGroup, isTrue);
        expect(recipients.isEmpty, isFalse);
      });
    }

    test('the payload names its recipients, and omits the key entirely for a '
        'ride-wide share', () {
      final contact = RiderContactShare(
        eventId: '',
        riderId: 'bill',
        displayName: 'Bill',
        phoneNumber: '+44 7700 900321',
        sharedAt: sharedAt,
        sharedByRole: RideRole.rider,
        toRideGroup: false,
      );

      final addressed = RiderContactShareReducer.payload(
        share: contact,
        recipients: const RiderContactRecipients.addressed([
          'leader',
          'leader',
          'tec',
        ]),
      );
      final rideWide = RiderContactShareReducer.payload(
        share: contact,
        recipients: const RiderContactRecipients.rideGroup(),
      );

      expect(addressed['recipientRiderIds'], ['leader', 'tec']);
      expect(rideWide.containsKey('recipientRiderIds'), isFalse);
      // The payload carries the number and nothing else personal: no ICE
      // contact, no medical notes, no position.
      expect((addressed['contact'] as Map).keys, {
        'riderId',
        'displayName',
        'phone',
        'sharedByRole',
      });
    });
  });

  group('a dialable number', () {
    test('keeps exactly what the rider typed', () {
      for (final accepted in [
        '+44 7700 900321',
        '07700900321',
        '(01234) 567890',
        '+1 555-0100',
        '  +44 7700 900321  ',
      ]) {
        final normalised = RiderContactShare.normalisePhoneNumber(accepted);
        expect(normalised, accepted.trim(), reason: accepted);
      }
    });

    test('never carries a scheme, a query or free text into a tel: URI', () {
      for (final rejected in [
        'tel:07700900321',
        '07700900321?body=x',
        '07700900321&x=1',
        '07700900321#1',
        'call the leader',
        '07700900321,,123',
        '+',
        '0770 <b>0900321</b>',
      ]) {
        expect(
          RiderContactShare.normalisePhoneNumber(rejected),
          isNull,
          reason: rejected,
        );
      }
    });

    test('is bounded in length so it cannot be used as a message channel', () {
      expect(RiderContactShare.normalisePhoneNumber('0' * 25), isNull);
      expect(RiderContactShare.normalisePhoneNumber('0' * 24), isNotNull);
    });
  });
}

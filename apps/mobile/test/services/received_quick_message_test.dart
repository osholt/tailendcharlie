import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/quick_message.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/services/geo_calculations.dart';
import 'package:ride_relay/services/received_quick_message.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';

const _rideId = 'ride-1';
const _secret = 'invite-secret';
final _now = DateTime.utc(2026, 7, 26, 12);

/// A signed `statusMessage`, exactly as `RideController.sendQuickMessage`
/// records one.
RideEvent _quickMessage({
  required String id,
  required String deviceId,
  required QuickMessage message,
  String? senderDisplayName,
  GeoPoint? position,
  List<String>? recipients,
  DateTime? createdAt,
  DateTime? expiresAt,
  String? label,
  String? rawMessageName,
  String secret = _secret,
}) {
  final unsigned = RideEvent(
    id: id,
    rideId: _rideId,
    deviceId: deviceId,
    type: RideEventType.statusMessage,
    priority: message.priority,
    createdAt: createdAt ?? _now,
    expiresAt: expiresAt ?? _now.add(const Duration(hours: 2)),
    payload: {
      'message': rawMessageName ?? message.name,
      'label': label ?? message.label,
      'senderDisplayName': ?senderDisplayName,
      'position': ?position?.toJson(),
      'recipientRiderIds': ?recipients,
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
    expiresAt: unsigned.expiresAt,
    payload: unsigned.payload,
    signature: RideEventAuthenticator.sign(unsigned, secret),
  );
}

RideEvent _acknowledgement({
  required String id,
  required String deviceId,
  required ReceivedQuickMessage message,
  String? displayName,
  DateTime? createdAt,
}) {
  final unsigned = RideEvent(
    id: id,
    rideId: _rideId,
    deviceId: deviceId,
    type: RideEventType.statusMessage,
    priority: EventPriority.important,
    createdAt: createdAt ?? _now.add(const Duration(seconds: 30)),
    expiresAt: _now.add(const Duration(hours: 2)),
    payload: {
      ...ReceivedQuickMessageReducer.acknowledgementPayload(message: message),
      'senderDisplayName': ?displayName,
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
    expiresAt: unsigned.expiresAt,
    payload: unsigned.payload,
    signature: RideEventAuthenticator.sign(unsigned, _secret),
  );
}

List<ReceivedQuickMessage> _reduce(
  List<RideEvent> events, {
  String localRiderId = 'leader',
  DateTime? now,
  Map<String, String> displayNames = const {},
  Iterable<String> departedRiderIds = const [],
  bool rideEnded = false,
}) => const ReceivedQuickMessageReducer().fromEvents(
  rideId: _rideId,
  inviteSecret: _secret,
  events: events,
  localRiderId: localRiderId,
  now: now ?? _now.add(const Duration(minutes: 1)),
  displayNames: displayNames,
  departedRiderIds: departedRiderIds,
  rideEnded: rideEnded,
);

void main() {
  test('a received quick message names the sender, the kind and the fix', () {
    final messages = _reduce([
      _quickMessage(
        id: 'msg-1',
        deviceId: 'bill',
        message: QuickMessage.fuel,
        senderDisplayName: 'Bill',
        position: const GeoPoint(latitude: 53, longitude: -1.02),
        recipients: const ['leader'],
      ),
    ]);

    expect(messages, hasLength(1));
    final message = messages.single;
    expect(message.senderRiderId, 'bill');
    expect(message.senderDisplayName, 'Bill');
    expect(message.message, QuickMessage.fuel);
    expect(message.label, 'Need fuel');
    expect(message.headline, 'Bill needs fuel');
    expect(message.raisedAtPosition?.latitude, 53);
    expect(message.addressedToLocalRider, isTrue);
    expect(message.raisedFromLocalRider, isFalse);
    expect(message.isAcknowledged, isFalse);
    expect(message.interrupts, isFalse);
  });

  test('the roster supplies a name the payload did not carry', () {
    final messages = _reduce(
      [
        _quickMessage(
          id: 'msg-1',
          deviceId: 'bill',
          message: QuickMessage.fuel,
        ),
      ],
      displayNames: const {'bill': 'Bill'},
    );

    expect(messages.single.headline, 'Bill needs fuel');
  });

  test('a message with no name anywhere is still presented', () {
    // An older build did not relay `senderDisplayName`, and a rider can raise
    // one before their membership event has arrived. The alert still has to say
    // something rather than being dropped.
    final messages = _reduce([
      _quickMessage(id: 'msg-1', deviceId: 'bill', message: QuickMessage.fuel),
    ]);

    expect(messages.single.headline, 'A rider needs fuel');
  });

  test('a kind only a newer build knows keeps the sender own words', () {
    final messages = _reduce([
      _quickMessage(
        id: 'msg-1',
        deviceId: 'bill',
        message: QuickMessage.mechanical,
        rawMessageName: 'tyrePressure',
        label: 'Low tyre',
        senderDisplayName: 'Bill',
      ),
    ]);

    final message = messages.single;
    expect(message.message, isNull);
    expect(message.label, 'Low tyre');
    expect(message.headline, 'Bill: Low tyre');
    // With no known kind the relayed envelope priority is what there is.
    expect(message.priority, EventPriority.important);
  });

  test('the most urgent message is first, then the newest', () {
    final messages = _reduce([
      _quickMessage(
        id: 'fuel',
        deviceId: 'bill',
        message: QuickMessage.fuel,
        senderDisplayName: 'Bill',
      ),
      _quickMessage(
        id: 'help',
        deviceId: 'ana',
        message: QuickMessage.assistance,
        senderDisplayName: 'Ana',
        createdAt: _now.subtract(const Duration(minutes: 5)),
      ),
      _quickMessage(
        id: 'blocked',
        deviceId: 'cal',
        message: QuickMessage.routeBlocked,
        senderDisplayName: 'Cal',
      ),
    ]);

    expect(messages.map((message) => message.eventId), const [
      'help',
      'blocked',
      'fuel',
    ]);
    expect(messages.first.interrupts, isTrue);
    expect(messages[1].isPressing, isTrue);
    expect(messages.last.interrupts, isFalse);
  });

  test('an acknowledgement is folded onto the message it names', () {
    final raised = _quickMessage(
      id: 'msg-1',
      deviceId: 'bill',
      message: QuickMessage.fuel,
      senderDisplayName: 'Bill',
    );
    final asBill = _reduce([raised], localRiderId: 'bill').single;
    final events = [
      raised,
      _acknowledgement(
        id: 'ack-1',
        deviceId: 'leader',
        message: asBill,
        displayName: 'Ana',
      ),
    ];

    // The sender sees who saw it, which is the whole point of raising one.
    final forSender = _reduce(events, localRiderId: 'bill').single;
    expect(forSender.raisedFromLocalRider, isTrue);
    expect(forSender.isAcknowledged, isTrue);
    expect(forSender.firstAcknowledgement?.displayName, 'Ana');
    expect(forSender.acknowledgedBy('leader'), isTrue);

    // And the rider who acknowledged it knows they already have.
    final forReader = _reduce(events).single;
    expect(forReader.acknowledgedBy('leader'), isTrue);

    // The acknowledgement is never itself a message on anybody's screen.
    expect(
      _reduce(events).where((message) => message.label.startsWith('Seen:')),
      isEmpty,
    );
  });

  test('an acknowledgement is recognisable in the journal', () {
    final raised = _quickMessage(
      id: 'msg-1',
      deviceId: 'bill',
      message: QuickMessage.fuel,
    );
    final message = _reduce([raised], localRiderId: 'bill').single;
    final ack = _acknowledgement(
      id: 'ack-1',
      deviceId: 'leader',
      message: message,
    );

    expect(ReceivedQuickMessageReducer.isAcknowledgement(ack), isTrue);
    expect(ReceivedQuickMessageReducer.isAcknowledgement(raised), isFalse);
    expect(ack.payload['label'], 'Seen: Need fuel');
    expect(ack.payload['recipientRiderIds'], const ['bill']);
  });

  test('Resolved from the same rider retires what they raised', () {
    final messages = _reduce([
      _quickMessage(
        id: 'msg-1',
        deviceId: 'bill',
        message: QuickMessage.fuel,
        senderDisplayName: 'Bill',
      ),
      _quickMessage(
        id: 'msg-2',
        deviceId: 'ana',
        message: QuickMessage.mechanical,
        senderDisplayName: 'Ana',
      ),
      _quickMessage(
        id: 'msg-3',
        deviceId: 'bill',
        message: QuickMessage.resolved,
        senderDisplayName: 'Bill',
        createdAt: _now.add(const Duration(seconds: 10)),
      ),
    ]);

    expect(messages.map((message) => message.senderRiderId), const ['ana']);
  });

  test('a message addressed to other riders is not this one to see', () {
    expect(
      _reduce([
        _quickMessage(
          id: 'msg-1',
          deviceId: 'bill',
          message: QuickMessage.fuel,
          recipients: const ['tec'],
        ),
      ]),
      isEmpty,
    );
  });

  test('a message with no recipient list is group-visible', () {
    // The dashboard grid sends one with no list, which is a rider telling the
    // whole group. Deliberately the opposite default from a rejoin share.
    expect(
      _reduce([
        _quickMessage(
          id: 'msg-1',
          deviceId: 'bill',
          message: QuickMessage.fuel,
        ),
      ]),
      hasLength(1),
    );
  });

  test('an unsigned, expired, departed or ended message is dropped', () {
    final forged = _quickMessage(
      id: 'forged',
      deviceId: 'bill',
      message: QuickMessage.assistance,
      secret: 'another-ride',
    );
    final expired = _quickMessage(
      id: 'expired',
      deviceId: 'bill',
      message: QuickMessage.fuel,
      createdAt: _now.subtract(const Duration(hours: 3)),
      expiresAt: _now.subtract(const Duration(hours: 1)),
    );
    final live = _quickMessage(
      id: 'live',
      deviceId: 'cal',
      message: QuickMessage.fuel,
    );

    expect(_reduce([forged]), isEmpty);
    expect(_reduce([expired]), isEmpty);
    expect(_reduce([live], departedRiderIds: const ['cal']), isEmpty);
    expect(_reduce([live], rideEnded: true), isEmpty);
    expect(_reduce([forged, expired, live]), hasLength(1));
  });

  test('an on-route sender is measured along the route, behind or ahead', () {
    const route = [
      GeoPoint(latitude: 53, longitude: -1.03),
      GeoPoint(latitude: 53, longitude: -1.02),
      GeoPoint(latitude: 53, longitude: -1.01),
      GeoPoint(latitude: 53, longitude: -1),
    ];

    final behind = QuickMessageOrigin.between(
      readerPosition: const GeoPoint(latitude: 53, longitude: -1.01),
      senderPosition: const GeoPoint(latitude: 53, longitude: -1.03),
      route: route,
    )!;
    expect(behind.alongRoute, isTrue);
    expect(behind.senderIsBehind, isTrue);
    expect(behind.distanceMeters, closeTo(1340, 40));
    expect(behind.bearingDegrees, isNull);

    final ahead = QuickMessageOrigin.between(
      readerPosition: const GeoPoint(latitude: 53, longitude: -1.03),
      senderPosition: const GeoPoint(latitude: 53, longitude: -1.01),
      route: route,
    )!;
    expect(ahead.senderIsBehind, isFalse);
  });

  test('a sender well off the route gets a bearing instead', () {
    const route = [
      GeoPoint(latitude: 53, longitude: -1.03),
      GeoPoint(latitude: 53, longitude: -1),
    ];

    final origin = QuickMessageOrigin.between(
      readerPosition: const GeoPoint(latitude: 53, longitude: -1.02),
      // Two kilometres north of the route, well past the 250 m on-route bound.
      senderPosition: const GeoPoint(latitude: 53.018, longitude: -1.02),
      route: route,
    )!;

    expect(origin.alongRoute, isFalse);
    expect(origin.senderIsBehind, isNull);
    expect(origin.compassLabel, 'N');
    expect(origin.distanceMeters, closeTo(2000, 60));
  });

  test('no route at all still yields a bearing and a distance', () {
    final origin = QuickMessageOrigin.between(
      readerPosition: const GeoPoint(latitude: 53, longitude: -1),
      senderPosition: const GeoPoint(latitude: 52.99, longitude: -1.01),
      route: const [],
    )!;

    expect(origin.alongRoute, isFalse);
    expect(origin.compassLabel, 'SW');
  });

  test('an unknown position is null rather than a zero distance', () {
    expect(
      QuickMessageOrigin.between(
        readerPosition: const GeoPoint(latitude: 53, longitude: -1),
        senderPosition: null,
      ),
      isNull,
    );
    expect(
      QuickMessageOrigin.between(
        readerPosition: null,
        senderPosition: const GeoPoint(latitude: 53, longitude: -1),
      ),
      isNull,
    );
  });

  test('every eight-point compass label is reachable and centred', () {
    const expected = <(double, String)>[
      (0, 'N'),
      (45, 'NE'),
      (90, 'E'),
      (135, 'SE'),
      (180, 'S'),
      (225, 'SW'),
      (270, 'W'),
      (315, 'NW'),
      (359, 'N'),
      (22, 'N'),
      (23, 'NE'),
    ];
    for (final (bearing, label) in expected) {
      expect(
        QuickMessageOrigin(
          distanceMeters: 100,
          alongRoute: false,
          bearingDegrees: bearing,
        ).compassLabel,
        label,
        reason: '$bearing degrees',
      );
    }
  });

  test('bearing is normalised clockwise from true north', () {
    const from = GeoPoint(latitude: 53, longitude: -1);
    expect(
      GeoCalculations.bearingDegrees(
        from,
        const GeoPoint(latitude: 53.01, longitude: -1),
      ),
      closeTo(0, 0.5),
    );
    expect(
      GeoCalculations.bearingDegrees(
        from,
        const GeoPoint(latitude: 53, longitude: -0.99),
      ),
      closeTo(90, 0.5),
    );
    expect(
      GeoCalculations.bearingDegrees(
        from,
        const GeoPoint(latitude: 52.99, longitude: -1),
      ),
      closeTo(180, 0.5),
    );
    expect(
      GeoCalculations.bearingDegrees(
        from,
        const GeoPoint(latitude: 53, longitude: -1.01),
      ),
      closeTo(270, 0.5),
    );
  });

  test('every quick message has a sentence naming the rider', () {
    for (final message in QuickMessage.values) {
      final sentence = message.sentenceFor('Bill');
      expect(sentence, startsWith('Bill'));
      expect(sentence.length, greaterThan('Bill'.length + 3));
    }
    expect(QuickMessage.fuel.sentenceFor('Bill'), 'Bill needs fuel');
    expect(QuickMessage.resolved.retiresEarlierMessages, isTrue);
    expect(QuickMessage.fuel.retiresEarlierMessages, isFalse);
  });

  test('an unrecognised kind name parses to null, a known one to itself', () {
    expect(tryParseQuickMessage('fuel'), QuickMessage.fuel);
    expect(tryParseQuickMessage('tyrePressure'), isNull);
    expect(tryParseQuickMessage(7), isNull);
    expect(tryParseQuickMessage(null), isNull);
  });
}

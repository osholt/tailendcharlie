import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/quick_message.dart';
import 'package:ride_relay/features/ride/active_ride_shell.dart';
import 'package:ride_relay/services/received_quick_message.dart';

/// The shell's half of #151: given the journal's admissible quick messages plus
/// whatever this phone knows about where everybody is, what does the ride map
/// get? This is the decision a two-device test exercises, made testable without
/// two devices.
void main() {
  ReceivedQuickMessage message({
    String eventId = 'msg-1',
    String senderRiderId = 'bill',
    String senderDisplayName = 'Bill',
    QuickMessage kind = QuickMessage.fuel,
    GeoPoint? raisedAtPosition,
    bool raisedFromLocalRider = false,
    List<String> acknowledgedBy = const [],
  }) => ReceivedQuickMessage(
    eventId: eventId,
    senderRiderId: senderRiderId,
    senderDisplayName: senderDisplayName,
    label: kind.label,
    priority: kind.priority,
    raisedAt: DateTime.utc(2026, 7, 26, 12),
    raisedFromLocalRider: raisedFromLocalRider,
    message: kind,
    raisedAtPosition: raisedAtPosition,
    acknowledgements: [
      for (final riderId in acknowledgedBy)
        QuickMessageAcknowledgement(
          riderId: riderId,
          displayName: riderId,
          acknowledgedAt: DateTime.utc(2026, 7, 26, 12, 1),
        ),
    ],
  );

  const route = [
    GeoPoint(latitude: 53, longitude: -1.03),
    GeoPoint(latitude: 53, longitude: -1.02),
    GeoPoint(latitude: 53, longitude: -1.01),
    GeoPoint(latitude: 53, longitude: -1),
  ];
  const readerPosition = GeoPoint(latitude: 53, longitude: -1.01);

  test('another rider message reaches the map with where they are', () {
    final presented = presentableQuickMessageAlerts(
      messages: [
        message(
          raisedAtPosition: const GeoPoint(latitude: 53, longitude: -1.03),
        ),
      ],
      localRiderId: 'leader',
      readerPosition: readerPosition,
      route: route,
    );

    expect(presented.alerts, hasLength(1));
    final alert = presented.alerts.single;
    expect(alert.message.headline, 'Bill needs fuel');
    expect(alert.origin?.alongRoute, isTrue);
    expect(alert.origin?.senderIsBehind, isTrue);
    expect(alert.origin?.positionIsLive, isFalse);
    // And their marker is the one that has to say what they raised.
    expect(presented.bySender.keys, const ['bill']);
  });

  test('a live fix wins over the fix relayed with the message', () {
    // Bill raised it a mile back and has since ridden up to the leader. Where he
    // is *now* is what a leader turning round needs.
    final presented = presentableQuickMessageAlerts(
      messages: [
        message(
          raisedAtPosition: const GeoPoint(latitude: 53, longitude: -1.03),
        ),
      ],
      localRiderId: 'leader',
      readerPosition: readerPosition,
      livePositions: const {'bill': GeoPoint(latitude: 53, longitude: -1.005)},
      route: route,
    );

    final origin = presented.alerts.single.origin!;
    expect(origin.positionIsLive, isTrue);
    expect(origin.senderIsBehind, isFalse);
    expect(origin.distanceMeters, closeTo(335, 30));
  });

  test('a sender with no fix at all is presented without an origin', () {
    // Honest absence, not a zero distance: the card says "position not reported".
    final presented = presentableQuickMessageAlerts(
      messages: [message()],
      localRiderId: 'leader',
      readerPosition: readerPosition,
      route: route,
    );

    expect(presented.alerts.single.origin, isNull);
  });

  test('acknowledging is what clears it from this phone', () {
    final messages = [
      message(acknowledgedBy: const ['leader']),
    ];

    // Gone for the rider who acknowledged it.
    expect(
      presentableQuickMessageAlerts(
        messages: messages,
        localRiderId: 'leader',
        readerPosition: readerPosition,
      ).alerts,
      isEmpty,
    );
    // Still outstanding for everybody else who can see it.
    expect(
      presentableQuickMessageAlerts(
        messages: messages,
        localRiderId: 'charlie',
        readerPosition: readerPosition,
      ).alerts,
      hasLength(1),
    );
  });

  test('this rider own message appears only as a receipt', () {
    final unseen = message(
      senderRiderId: 'leader',
      senderDisplayName: 'Me',
      raisedFromLocalRider: true,
    );
    final seen = message(
      senderRiderId: 'leader',
      senderDisplayName: 'Me',
      raisedFromLocalRider: true,
      acknowledgedBy: const ['bill'],
    );

    // Nobody needs their own alert read back to them.
    expect(
      presentableQuickMessageAlerts(
        messages: [unseen],
        localRiderId: 'leader',
        readerPosition: readerPosition,
      ).alerts,
      isEmpty,
    );
    // Once somebody has seen it, that is worth saying - and it is not an alert,
    // so it never claims a sender marker.
    final receipt = presentableQuickMessageAlerts(
      messages: [seen],
      localRiderId: 'leader',
      readerPosition: readerPosition,
    );
    expect(receipt.alerts, hasLength(1));
    expect(receipt.alerts.single.message.firstAcknowledgement?.riderId, 'bill');
    expect(receipt.bySender, isEmpty);
  });

  test('one marker per sender, the most urgent thing they raised', () {
    // The reducer hands them over most urgent first, so the first message from a
    // rider is the one their marker should carry.
    final presented = presentableQuickMessageAlerts(
      messages: [
        message(eventId: 'help', kind: QuickMessage.assistance),
        message(eventId: 'fuel'),
      ],
      localRiderId: 'leader',
      readerPosition: readerPosition,
    );

    expect(presented.alerts, hasLength(2));
    expect(presented.bySender['bill']?.eventId, 'help');
    expect(presented.bySender['bill']?.interrupts, isTrue);
  });

  test('a reader with no fix of their own still gets the message', () {
    // The message is the point; the distance is the bonus. A phone that has not
    // got a fix yet must still be told somebody needs help.
    final presented = presentableQuickMessageAlerts(
      messages: [
        message(
          kind: QuickMessage.assistance,
          raisedAtPosition: const GeoPoint(latitude: 53, longitude: -1.03),
        ),
      ],
      localRiderId: 'leader',
      readerPosition: null,
      route: route,
    );

    expect(presented.alerts.single.message.headline, 'Bill needs help');
    expect(presented.alerts.single.origin, isNull);
  });
}

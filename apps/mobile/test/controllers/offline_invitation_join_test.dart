import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/domain/ride_join_payload.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/nearby_bridge.dart';

/// The offline claim in #279, proven against a relay that genuinely cannot be
/// reached.
///
/// The unit test elsewhere uses a fake directory that throws, which shows the code
/// path does not *call* the relay. This one goes further and uses the **real**
/// `HttpRideCodeDirectory` pointed at a refusing endpoint, so what is being
/// asserted is the behaviour a rider in a car park with no signal actually gets:
/// the ordinary join fails, and scanning still works.
///
/// Port 1 on loopback refuses immediately. That matters for a test - an
/// unroutable address like TEST-NET-3 would prove the same thing but would sit
/// there until a connect timeout, and a slow test is a test people stop running.
void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  const joinToken = 'resolve-token-0123456789';

  late RideController controller;
  late http.Client client;
  late RideCodeDirectory unreachableRelay;

  setUp(() {
    client = http.Client();
    unreachableRelay = HttpRideCodeDirectory(
      configuration: InternetRelayConfiguration(
        baseUri: Uri.parse('http://127.0.0.1:1/api'),
      ),
      client: client,
    );
    var id = 0;
    controller = RideController(
      InMemoryEventStore(),
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => DateTime.utc(2026, 8, 1, 9),
      idFactory: () => 'offline-${id++}',
      random: Random(11),
      rideCodeDirectory: unreachableRelay,
      completedRideStore: InMemoryCompletedRideStore(),
    );
  });

  tearDown(() {
    controller.dispose();
    client.close();
  });

  test('the ordinary join cannot work with the relay unreachable', () async {
    // Establishes that the endpoint really is dead, so the next test is proving
    // something rather than passing by accident.
    await controller.joinRide('934893', 'Rider');

    expect(controller.hasActiveRide, isFalse);
    expect(
      controller.errorMessage,
      isNotNull,
      reason: 'joining by code needs the relay, and it is not there',
    );
  });

  test('a scanned invitation joins anyway', () async {
    const invitation = RideJoinPayload(
      rideId: 'ride-from-a-car-park',
      rideCode: '135627',
      inviteSecret: secret,
      joinToken: joinToken,
    );

    await controller.joinRideFromInvitation(invitation, 'Scanned rider');

    expect(controller.errorMessage, isNull);
    expect(controller.hasActiveRide, isTrue);

    final session = controller.session!;
    expect(session.rideId, 'ride-from-a-car-park');
    expect(session.rideCode, '135627');
    expect(session.role, RideRole.rider);
    // The credentials that make authenticated transport possible have to survive
    // intact. Without them the rider holds a session that looks joined and can
    // reach nobody once signal returns.
    expect(session.inviteSecret, secret);
    expect(session.joinToken, joinToken);

    // A real join, not just a stored session: the roster shows this rider, which
    // means the riderJoined event was recorded.
    expect(
      controller.participants.map((participant) => participant.displayName),
      contains('Scanned rider'),
    );
  });

  test('it is fast, because nothing waits on a network', () async {
    const invitation = RideJoinPayload(
      rideId: 'ride-from-a-car-park',
      rideCode: '135627',
      inviteSecret: secret,
      joinToken: joinToken,
    );

    final started = DateTime.now();
    await controller.joinRideFromInvitation(invitation, 'Scanned rider');
    final elapsed = DateTime.now().difference(started);

    expect(controller.hasActiveRide, isTrue);
    // Generous, because a loaded CI machine is not a benchmark. The point is that
    // it cannot have waited on a connect attempt, which is what any accidental
    // reintroduction of a relay call would cost.
    expect(
      elapsed,
      lessThan(const Duration(seconds: 2)),
      reason: 'an offline join must not be waiting on anything',
    );
  });
}

class _FakeNearbyBridge implements NearbyBridge {
  const _FakeNearbyBridge();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

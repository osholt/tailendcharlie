import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/controllers/test_control_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:ride_relay/services/test_control_configuration.dart';
import 'package:ride_relay/services/test_control_registry.dart';
import 'package:ride_relay/services/test_control_server.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// End-to-end exercise of the test-control surface over real HTTP.
///
/// Only runs with `--dart-define=RIDE_RELAY_TEST_CONTROL=true`, and skips itself
/// otherwise, because the ordinary suite must run in the configuration a release
/// build uses - where the surface does not exist. Run it with:
///
/// ```bash
/// flutter test --dart-define=RIDE_RELAY_TEST_CONTROL=true \
///   test/services/test_control_server_enabled_test.dart
/// ```
///
/// The companion `test_control_server_test.dart` asserts the opposite and runs
/// always: without the define, the surface is inert.
void main() {
  // A named condition rather than a bare bool, so a skipped run says why.
  final withoutDefine = TestControlConfiguration.enabled
      ? null
      : 'needs --dart-define=RIDE_RELAY_TEST_CONTROL=true';

  group('test-control surface, define on', () {
    late TestControlController control;
    late TestControlServer server;
    late RideController ride;
    late TestControlRegistry registry;
    // A port of its own, so a run cannot collide with a real driven build or
    // with a parallel test shard.
    const port = 8479;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      control = await TestControlController.load();
      ride = RideController(
        InMemoryEventStore(),
        InMemorySessionStore(),
        const _FakeNearbyBridge(),
        completedRideStore: InMemoryCompletedRideStore(),
      );
      registry = TestControlRegistry();
      server = TestControlServer(
        control,
        ride,
        registry,
        configuration: const TestControlConfiguration(port: port),
      );
    });

    tearDown(() async {
      await server.stop();
      ride.dispose();
    });

    Future<HttpClientResponse> send(
      String method,
      String path, {
      String? token,
      Object? body,
    }) async {
      final client = HttpClient();
      final request = await client.open(method, '127.0.0.1', port, path)
        ..headers.contentType = ContentType.json;
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (body != null) request.write(jsonEncode(body));
      return request.close();
    }

    Future<Map<String, Object?>> readJson(HttpClientResponse response) async =>
        jsonDecode(await response.transform(utf8.decoder).join())
            as Map<String, Object?>;

    test('binds no port until the switch is turned on', () async {
      await server.start();
      expect(
        server.isListening,
        isFalse,
        reason: 'the define alone must not open a port',
      );

      await control.setForTesting(
        on: true,
        token: 'field-test-token-abcdefghij',
      );
      await server.start();

      expect(server.isListening, isTrue);
      expect(server.port, port);
    });

    test('stops listening when the switch is turned off', () async {
      await control.setForTesting(
        on: true,
        token: 'field-test-token-abcdefghij',
      );
      await server.start();
      expect(server.isListening, isTrue);

      await server.stop();
      expect(server.isListening, isFalse);
      await expectLater(
        send('GET', '/v1/health'),
        throwsA(isA<SocketException>()),
      );
    });

    test('health is unauthenticated and says nothing about the ride', () async {
      await control.setForTesting(
        on: true,
        token: 'field-test-token-abcdefghij',
      );
      await server.start();

      final body = await readJson(await send('GET', '/v1/health'));

      expect(body['status'], 'ok');
      expect(body['switchedOn'], isTrue);
      expect(
        body.keys,
        isNot(contains('roster')),
        reason:
            'liveness must not leak ride state to an unauthenticated caller',
      );
    });

    test('a missing, empty or wrong token is rejected', () async {
      await control.setForTesting(
        on: true,
        token: 'field-test-token-abcdefghij',
      );
      await server.start();

      for (final token in <String?>[null, '', 'not-the-token']) {
        final response = await send('GET', '/v1/state', token: token);
        expect(
          response.statusCode,
          HttpStatus.unauthorized,
          reason: 'token ${token ?? '<absent>'} must be rejected',
        );
      }
    });

    test('the issued token is accepted and returns a snapshot', () async {
      await control.setForTesting(
        on: true,
        token: 'field-test-token-abcdefghij',
      );
      await server.start();

      final response = await send('GET', '/v1/state', token: control.token);
      expect(response.statusCode, HttpStatus.ok);

      final body = await readJson(response);
      expect(body, contains('reconciliation'));
      expect(body, contains('roster'));
      expect(body, contains('presence'));
      // No ride yet, so nothing to report and nothing to be wrong about.
      expect(body['ride'], isNull);
    });

    test('a snapshot never carries capability material', () async {
      await control.setForTesting(
        on: true,
        token: 'field-test-token-abcdefghij',
      );
      await server.start();

      final raw = await (await send(
        'GET',
        '/v1/state',
        token: control.token,
      )).transform(utf8.decoder).join();

      // A snapshot is meant to be safe to paste into a results document.
      expect(raw, isNot(contains('inviteSecret')));
      expect(raw, isNot(contains('joinToken')));
    });

    test('a forbidden action is refused even with a valid token', () async {
      await control.setForTesting(
        on: true,
        token: 'field-test-token-abcdefghij',
      );
      await server.start();

      for (final path in <String>[
        '/v1/sos',
        '/v1/emergency',
        '/v1/ride/ice',
        '/v1/call',
      ]) {
        final response = await send('POST', path, token: control.token);
        expect(
          response.statusCode,
          HttpStatus.forbidden,
          reason: '$path must be refused outright',
        );
      }
    });

    test('a hazard with no active ride is a conflict, not a crash', () async {
      await control.setForTesting(
        on: true,
        token: 'field-test-token-abcdefghij',
      );
      await server.start();

      final response = await send(
        'POST',
        '/v1/hazard',
        token: control.token,
        body: {'type': 'roadworks', 'latitude': 51.2, 'longitude': -2.4},
      );

      expect(response.statusCode, HttpStatus.conflict);
      expect((await readJson(response))['error'], 'invalid_state');
    });

    test('a malformed body is a bad request naming the field', () async {
      await control.setForTesting(
        on: true,
        token: 'field-test-token-abcdefghij',
      );
      await server.start();

      final response = await send(
        'POST',
        '/v1/ride',
        token: control.token,
        body: {'displayName': ''},
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect((await readJson(response))['detail'], contains('displayName'));
    });

    test('a swallowed controller failure is reported, not answered 200', () async {
      await control.setForTesting(
        on: true,
        token: 'field-test-token-abcdefghij',
      );
      await server.start();

      // endRide on a ride the local rider does not lead throws a
      // FormatException, which RideController._run captures into errorMessage
      // instead of rethrowing. Before this was handled, the surface answered 200
      // with a snapshot of the unchanged ride - a driven field test would have
      // recorded a successful end against a ride that never ended.
      await ride.createRide('Leader');
      final before = ride.session?.rideId;

      final response = await send(
        'POST',
        '/v1/ride/join',
        token: control.token,
        body: {'rideCode': 'not-six-digits', 'displayName': 'Follower'},
      );

      expect(
        response.statusCode,
        anyOf(HttpStatus.badRequest, HttpStatus.conflict),
        reason: 'a failed action must not answer 200',
      );
      final body = await readJson(response);
      expect(body['error'], 'action_failed');
      expect(body['detail'], isNotEmpty);
      // The state still comes back, because a driver deciding whether to abandon
      // a run needs to know where the ride actually got to.
      expect(body['state'], isA<Map<String, Object?>>());
      expect(
        ride.session?.rideId,
        before,
        reason: 'the ride must be unchanged by the failed action',
      );
    });

    test('a token shorter than the minimum serves nothing', () async {
      // A weak token is a worse failure than a missing one, because it looks
      // like it works. The switch alone must not open the surface.
      await control.setForTesting(on: true, token: 'short');
      expect(control.isOn, isFalse);
      expect(control.needsToken, isTrue);

      await server.start();
      expect(
        server.isListening,
        isFalse,
        reason: 'no port may be bound without a usable token',
      );
    });

    test('the operator token survives a controller reload', () async {
      // The point of the re-architecture: a restart must not invalidate the
      // token, because the previous design needed a person to read a new one
      // after every launch and that made restart tests undrivable.
      await control.setForTesting(
        on: true,
        token: 'field-test-token-abcdefghij',
      );
      await server.start();
      expect(
        (await send(
          'GET',
          '/v1/state',
          token: 'field-test-token-abcdefghij',
        )).statusCode,
        HttpStatus.ok,
      );

      final reloaded = await TestControlController.load();
      expect(reloaded.isOn, isTrue);
      expect(
        reloaded.token,
        'field-test-token-abcdefghij',
        reason: 'the same token must still authenticate after a relaunch',
      );
    });
  }, skip: withoutDefine);
}

class _FakeNearbyBridge implements NearbyBridge {
  const _FakeNearbyBridge();

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

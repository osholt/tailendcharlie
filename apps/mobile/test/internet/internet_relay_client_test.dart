import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';

void main() {
  group('HttpInternetRelayClient', () {
    test('is disabled unless an absolute HTTPS endpoint is configured', () {
      expect(
        const InternetRelayConfiguration(baseUri: null).isConfigured,
        isFalse,
      );
      expect(
        InternetRelayConfiguration(
          baseUri: Uri.parse('http://relay.example'),
        ).isConfigured,
        isFalse,
      );
      expect(
        InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example/api'),
        ).isConfigured,
        isTrue,
      );
    });

    test('sends a bounded authenticated idempotent sync request', () async {
      final requests = <http.Request>[];
      final remote = _event(id: 'remote-event', deviceId: 'remote-device');
      final transport = MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'protocolVersion': 1,
            'cursor': 'cursor-2',
            'acceptedEventIds': ['local-event'],
            'events': [remote.toJson()],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final client = HttpInternetRelayClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example/base'),
        ),
        client: transport,
      );

      final first = await client.synchronize(
        session: _session,
        cursor: 'cursor-1',
        events: [_event(id: 'local-event')],
      );
      await client.synchronize(
        session: _session,
        cursor: 'cursor-1',
        events: [_event(id: 'local-event')],
      );

      expect(first.cursor, 'cursor-2');
      expect(first.acceptedEventIds, {'local-event'});
      expect(first.events.single.id, 'remote-event');
      expect(requests, hasLength(2));
      expect(requests.first.followRedirects, isFalse);
      expect(
        requests.first.url.path,
        '/base/v1/rides/ride%2Falpha/events:sync',
      );
      expect(
        requests.first.headers['authorization'],
        startsWith('Bearer rr1_'),
      );
      expect(
        requests.first.headers['authorization'],
        isNot(contains(_session.inviteSecret)),
      );
      expect(
        requests.first.headers['idempotency-key'],
        requests.last.headers['idempotency-key'],
      );
      expect(jsonDecode(requests.first.body)['protocolVersion'], 1);
      client.close();
    });

    test('rejects events for another ride in a successful response', () async {
      final transport = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'protocolVersion': 1,
            'cursor': 'cursor-2',
            'acceptedEventIds': <String>[],
            'events': [_event(id: 'foreign', rideId: 'other').toJson()],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final client = HttpInternetRelayClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example'),
        ),
        client: transport,
      );

      await expectLater(
        client.synchronize(session: _session, cursor: null, events: const []),
        throwsA(isA<InternetRelayException>()),
      );
      client.close();
    });

    test('rejects an oversized response before decoding it', () async {
      final transport = MockClient(
        (_) async => http.Response(
          'x' * 65,
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final client = HttpInternetRelayClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example'),
          maximumResponseBytes: 64,
        ),
        client: transport,
      );

      await expectLater(
        client.synchronize(session: _session, cursor: null, events: const []),
        throwsA(
          isA<InternetRelayException>().having(
            (error) => error.message,
            'message',
            contains('size limit'),
          ),
        ),
      );
      client.close();
    });

    test('bounds the wait for response headers', () async {
      final client = HttpInternetRelayClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example'),
          headerTimeout: const Duration(milliseconds: 10),
        ),
        client: _NeverRespondingClient(),
      );

      await expectLater(
        client.synchronize(session: _session, cursor: null, events: const []),
        throwsA(
          isA<InternetRelayException>()
              .having((error) => error.retryable, 'retryable', isTrue)
              .having((error) => error.message, 'message', contains('headers')),
        ),
      );
      client.close();
    });
  });
}

class _NeverRespondingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

final _session = RideSession(
  rideId: 'ride/alpha',
  rideCode: 'ALPHA1',
  inviteSecret: '0123456789abcdef0123456789abcdef',
  localRiderId: 'local-device',
  displayName: 'Oliver',
  role: RideRole.rider,
  joinedAt: DateTime.utc(2026, 7, 16),
);

RideEvent _event({
  required String id,
  String rideId = 'ride/alpha',
  String deviceId = 'local-device',
}) => RideEvent(
  id: id,
  rideId: rideId,
  deviceId: deviceId,
  type: RideEventType.statusMessage,
  priority: EventPriority.routine,
  createdAt: DateTime.utc(2026, 7, 16, 10),
  payload: const {'message': 'OK'},
  signature: 'a' * 64,
);

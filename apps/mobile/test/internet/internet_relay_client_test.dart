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

    test('negotiates current relay capabilities', () async {
      final requests = <http.Request>[];
      final client = HttpInternetRelayClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example/base'),
        ),
        client: MockClient((request) async {
          requests.add(request);
          return _compatibilityResponse();
        }),
        clientDescriptor: _clientDescriptor,
        clock: () => DateTime.utc(2026, 7, 22),
      );

      final result = await client.checkCompatibility();

      expect(result.disposition, RelayCompatibilityDisposition.compatible);
      expect(result.capabilities, RelayProtocolCapabilities.current);
      expect(requests.single.url.path, '/base/v1/compatibility');
      expect(requests.single.headers['x-tailendcharlie-protocol'], '1');
      expect(
        requests.single.headers['x-tailendcharlie-capabilities'],
        contains(RelayProtocolCapabilities.routeRevisions),
      );
      client.close();
    });

    test(
      'uses a bounded legacy mode when compatibility is unavailable',
      () async {
        final client = HttpInternetRelayClient(
          configuration: InternetRelayConfiguration(
            baseUri: Uri.parse('https://relay.example'),
          ),
          client: MockClient((_) async => http.Response('', 404)),
          clientDescriptor: _clientDescriptor,
          clock: () => DateTime.utc(2026, 7, 22),
        );

        final result = await client.checkCompatibility();

        expect(
          result.disposition,
          RelayCompatibilityDisposition.legacyCompatible,
        );
        expect(result.canSynchronize, isTrue);
        expect(result.capabilities, isEmpty);
        client.close();
      },
    );

    test('requires an update below the server minimum protocol', () async {
      final client = HttpInternetRelayClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example'),
        ),
        client: MockClient(
          (_) async => _compatibilityResponse(minimumClientProtocol: 2),
        ),
        clientDescriptor: _clientDescriptor,
        clock: () => DateTime.utc(2026, 7, 22),
      );

      final result = await client.checkCompatibility();

      expect(result.disposition, RelayCompatibilityDisposition.updateRequired);
      expect(result.canSynchronize, isFalse);
      expect(result.updateUri, Uri.parse('https://tailendcharlie.app/update'));
      client.close();
    });

    test('does not expose a failed relay hostname in diagnostics', () async {
      final client = HttpInternetRelayClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://retired.internal.example'),
        ),
        client: MockClient(
          (_) async => throw http.ClientException(
            'Failed host lookup: retired.internal.example',
          ),
        ),
        clientDescriptor: _clientDescriptor,
      );

      await expectLater(
        client.checkCompatibility(),
        throwsA(
          isA<InternetRelayException>()
              .having(
                (error) => error.message,
                'message',
                isNot(contains('retired.internal.example')),
              )
              .having((error) => error.retryable, 'retryable', isTrue),
        ),
      );
      client.close();
    });
  });

  group('HttpRideCodeDirectory', () {
    test(
      'registers and resolves a six-digit code over the configured relay',
      () async {
        final requests = <http.Request>[];
        final transport = MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/v1/compatibility')) {
            return _compatibilityResponse();
          }
          if (request.method == 'PUT') {
            return http.Response('', 204);
          }
          return http.Response(
            jsonEncode({
              'rideId': _session.rideId,
              'rideCode': '123456',
              'inviteSecret': _session.inviteSecret,
              'resolveToken': _session.joinToken,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final directory = HttpRideCodeDirectory(
          configuration: InternetRelayConfiguration(
            baseUri: Uri.parse('https://relay.example/base'),
          ),
          client: transport,
        );
        final leader = _session.copyWith(rideCode: '123456');

        await directory.register(leader);
        final resolved = await directory.resolve('123456');

        expect(resolved.rideId, _session.rideId);
        expect(resolved.rideCode, '123456');
        expect(resolved.inviteSecret, _session.inviteSecret);
        expect(resolved.joinToken, _session.joinToken);
        expect(requests, hasLength(3));
        expect(requests.first.url.path, '/base/v1/compatibility');
        expect(requests[1].method, 'PUT');
        expect(requests[1].url.path, '/base/v1/join-codes/123456');
        expect(requests[1].followRedirects, isFalse);
        expect(jsonDecode(requests[1].body), {
          'rideId': _session.rideId,
          'inviteSecret': _session.inviteSecret,
          'resolveToken': _session.joinToken,
        });
        expect(requests.last.method, 'GET');
        expect(
          requests.last.headers.containsKey('x-ride-relay-join-token'),
          isFalse,
        );
        directory.close();
      },
    );

    test('sends the join token header only when one is supplied', () async {
      final requests = <http.Request>[];
      final transport = MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/v1/compatibility')) {
          return _compatibilityResponse();
        }
        return http.Response(
          jsonEncode({
            'rideId': _session.rideId,
            'rideCode': '123456',
            'inviteSecret': _session.inviteSecret,
            'resolveToken': _session.joinToken,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final directory = HttpRideCodeDirectory(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example/base'),
        ),
        client: transport,
      );

      await directory.resolve('123456', joinToken: 'pastedTokenValue123456');

      expect(
        requests.last.headers['x-ride-relay-join-token'],
        'pastedTokenValue123456',
      );
      directory.close();
    });
  });
}

const _clientDescriptor = RelayClientDescriptor(
  protocolVersion: 1,
  platform: 'iOS',
  appVersion: '1.0.1',
  appBuild: '22',
  capabilities: RelayProtocolCapabilities.current,
);

http.Response _compatibilityResponse({int minimumClientProtocol = 1}) =>
    http.Response(
      jsonEncode({
        'serverProtocol': 1,
        'minimumClientProtocol': minimumClientProtocol,
        'maximumClientProtocol': 1,
        'capabilities': RelayProtocolCapabilities.current.toList(),
        'requiredCapabilities': <String>[],
        'cacheSeconds': 300,
        'updateUrls': {
          'default': 'https://tailendcharlie.app/update',
          'iOS': 'https://tailendcharlie.app/update',
          'android': 'https://tailendcharlie.app/update',
        },
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

class _NeverRespondingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;
}

final _session = RideSession(
  rideId: 'ride/alpha',
  rideCode: 'ALPHA1',
  inviteSecret: '0123456789abcdef0123456789abcdef',
  joinToken: 'aTokenWithPlentyOfEntropy',
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

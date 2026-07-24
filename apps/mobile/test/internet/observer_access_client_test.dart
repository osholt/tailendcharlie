import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/internet/observer_access_client.dart';

void main() {
  final session = RideSession(
    rideId: 'ride-observer',
    rideCode: '123456',
    inviteSecret: 'observer-secret-0123456789012345',
    joinToken: 'join-token-0123456789',
    localRiderId: 'rider-a',
    displayName: 'Oliver',
    role: RideRole.rider,
    joinedAt: DateTime(2026, 7, 24),
  );
  final configuration = ObserverAccessConfiguration(
    relay: InternetRelayConfiguration(
      baseUri: Uri.parse('https://relay.example/api'),
    ),
    webBaseUri: Uri.parse('https://relay.example/observer.html'),
  );

  test('configuration requires separate HTTPS relay and web addresses', () {
    expect(configuration.configurationError, isNull);
    expect(
      ObserverAccessConfiguration(
        relay: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example/api'),
        ),
        webBaseUri: Uri.parse('https://example.test/observer.html?token=x'),
      ).configurationError,
      contains('HTTPS web address'),
    );
    expect(
      ObserverAccessConfiguration(
        relay: InternetRelayConfiguration(
          baseUri: Uri.parse('https://preprod-relay.example/api'),
        ),
        webBaseUri: Uri.parse('https://relay.example/observer.html'),
      ).configurationError,
      contains('same service host'),
    );
  });

  test('creates validated credentials and a fragment-only read link', () async {
    late http.Request captured;
    final client = HttpObserverAccessClient(
      configuration: configuration,
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(_grantJson(includeTokens: true)),
          201,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    final credentials = await client.create(
      session,
      label: 'Home contact',
      duration: const Duration(hours: 4),
    );
    final shareUri = client.shareUri(credentials);

    expect(
      captured.url.toString(),
      'https://relay.example/api/v1/rides/ride-observer/observer-grants',
    );
    expect(captured.headers['authorization'], startsWith('Bearer rr1_'));
    expect(captured.headers, isNot(contains('x-ride-relay-device')));
    expect(jsonDecode(captured.body), {
      'label': 'Home contact',
      'durationMinutes': 240,
      'consentConfirmed': true,
    });
    expect(shareUri.query, isEmpty);
    expect(shareUri.fragment, '${credentials.grant.id}.$observerToken');
    expect(shareUri.toString(), isNot(contains(managementToken)));
    expect(shareUri.toString(), isNot(contains(publisherToken)));
  });

  test('rejects malformed server-issued secrets before persistence', () async {
    final client = HttpObserverAccessClient(
      configuration: configuration,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            ..._grantJson(includeTokens: true),
            'observerToken': 'bad',
          }),
          201,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    await expectLater(
      client.create(session, label: 'Home', duration: const Duration(hours: 1)),
      throwsA(isA<InternetRelayException>()),
    );
  });

  test('uses a different credential for inspect, publish and revoke', () async {
    final requests = <http.Request>[];
    final client = HttpObserverAccessClient(
      configuration: configuration,
      client: MockClient((request) async {
        requests.add(request);
        if (request.method == 'GET') {
          return http.Response(
            jsonEncode(_grantJson()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 204);
      }),
    );
    final credentials = ObserverGrantCredentials.fromJson({
      'grant': _grantJson(),
      'managementToken': managementToken,
      'publisherToken': publisherToken,
      'observerToken': observerToken,
    });
    final now = DateTime.utc(2026, 7, 24, 12);

    await client.inspect(credentials);
    await client.publish(
      credentials,
      ObserverPublishedSnapshot(
        subjectName: 'Oliver',
        snapshotGeneratedAt: now,
        rideStatus: 'waiting',
        statusUpdatedAt: now,
        assistanceUpdatedAt: now,
      ),
    );
    await client.revoke(credentials);

    expect(requests.map((request) => request.method), ['GET', 'PUT', 'DELETE']);
    expect(requests.map((request) => request.headers['authorization']), [
      'Bearer $managementToken',
      'Bearer $publisherToken',
      'Bearer $managementToken',
    ]);
  });
}

const managementToken = 'om1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const publisherToken = 'op1_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB';
const observerToken = 'ro1_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';

Map<String, Object?> _grantJson({bool includeTokens = false}) => {
  'id': '123e4567-e89b-42d3-a456-426614174000',
  'label': 'Home contact',
  'createdAt': '2026-07-24T12:00:00Z',
  'expiresAt': '2026-07-24T16:00:00Z',
  'revokedAt': null,
  if (includeTokens) ...{
    'managementToken': managementToken,
    'publisherToken': publisherToken,
    'observerToken': observerToken,
  },
};

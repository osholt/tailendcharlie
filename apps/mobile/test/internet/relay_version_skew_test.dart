import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/relay/relay_event_compatibility.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';

/// Mixed tester builds are the normal case, so both skew directions must keep
/// the core group functions working or say precisely what is unavailable.
void main() {
  final now = DateTime.utc(2026, 7, 25, 11);

  group('describeUnsupportedRelayEvent', () {
    test('accepts every event type this build knows', () {
      for (final type in RideEventType.values) {
        expect(
          describeUnsupportedRelayEvent(_rawEvent(type: type.name)),
          isNull,
          reason: type.name,
        );
      }
    });

    test('flags a future event type, schema version and envelope field', () {
      expect(
        describeUnsupportedRelayEvent(_rawEvent(type: 'rideTeleported')),
        'rideTeleported',
      );
      expect(
        describeUnsupportedRelayEvent(_rawEvent(schemaVersion: 2)),
        'schema-v2',
      );
      expect(
        describeUnsupportedRelayEvent(_rawEvent(extra: {'convoyId': 'c-1'})),
        'statusMessage+fields',
      );
    });

    test('never returns caller-controlled punctuation or a URL', () {
      final label = describeUnsupportedRelayEvent(
        _rawEvent(type: 'evil https://attacker.example/?a=b\n\r'),
      );

      expect(label, isNotNull);
      expect(label, isNot(contains('/')));
      expect(label, isNot(contains(':')));
      expect(label, isNot(contains('\n')));
      expect(sanitiseRelayToken('///'), 'unknown');
      expect(sanitiseRelayToken('a' * 100).length, 32);
    });
  });

  test(
    'a newer peer event is skipped and the rest of the batch is delivered',
    () async {
      final known = _signedEvent(id: 'known', deviceId: 'peer');
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode({
            'protocolVersion': 1,
            'cursor': 'cursor-1',
            'acceptedEventIds': <String>[],
            'events': [
              _rawEvent(id: 'future', type: 'rideTeleported'),
              known.toJson(),
              _rawEvent(id: 'future-schema', schemaVersion: 2),
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      final api = HttpInternetRelayClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example/api'),
        ),
        client: client,
        clock: () => now,
      );

      final result = await api.synchronize(
        session: _session,
        cursor: null,
        events: const [],
      );

      // The known event survives and the cursor advances: one unknown type must
      // not stall the batch forever and hide every rider.
      expect(result.events.map((event) => event.id), ['known']);
      expect(result.cursor, 'cursor-1');
      expect(result.ignoredEventCount, 2);
      expect(result.ignoredEventTypes, {'rideTeleported', 'schema-v2'});
    },
  );

  test('a structurally invalid event is still an error', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'protocolVersion': 1,
          'cursor': 'cursor-1',
          'acceptedEventIds': <String>[],
          'events': [_rawEvent(signature: 'not-a-signature')],
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final api = HttpInternetRelayClient(
      configuration: InternetRelayConfiguration(
        baseUri: Uri.parse('https://relay.example/api'),
      ),
      client: client,
      clock: () => now,
    );

    await expectLater(
      api.synchronize(session: _session, cursor: null, events: const []),
      throwsA(isA<InternetRelayException>()),
    );
  });

  test('an invalid response never quotes the transport error text', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'protocolVersion': 1,
          'cursor': 'cursor-1',
          'acceptedEventIds': <String>[],
          'events': [
            {'type': 'statusMessage', 'payload': 'relay.internal.example'},
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final api = HttpInternetRelayClient(
      configuration: InternetRelayConfiguration(
        baseUri: Uri.parse('https://relay.example/api'),
      ),
      client: client,
      clock: () => now,
    );

    await expectLater(
      api.synchronize(session: _session, cursor: null, events: const []),
      throwsA(
        isA<InternetRelayException>().having(
          (error) => error.message,
          'message',
          'Internet relay returned a response this app could not read.',
        ),
      ),
    );
  });

  test('a TLS failure diagnostic never names the relay host', () async {
    final client = MockClient(
      (request) async => throw const _HostNamingException(),
    );
    final api = HttpInternetRelayClient(
      configuration: InternetRelayConfiguration(
        baseUri: Uri.parse('https://relay.internal.example/api'),
      ),
      client: client,
      clock: () => now,
    );

    await expectLater(
      api.checkCompatibility(),
      throwsA(
        isA<InternetRelayException>()
            .having(
              (error) => error.message,
              'message',
              isNot(contains('relay.internal.example')),
            )
            .having((error) => error.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('an unknown server capability is ignored, not fatal', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode({
          'serverProtocol': 1,
          'minimumClientProtocol': 1,
          'maximumClientProtocol': 1,
          'capabilities': [
            ...RelayProtocolCapabilities.current,
            'convoy-formations-v7',
          ],
          'requiredCapabilities': <String>[],
          'cacheSeconds': 300,
          'updateUrls': {'default': 'https://tailendcharlie.app'},
          'somethingNewEntirely': {'nested': true},
        }),
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    final api = HttpInternetRelayClient(
      configuration: InternetRelayConfiguration(
        baseUri: Uri.parse('https://relay.example/api'),
      ),
      client: client,
      clock: () => now,
    );

    final result = await api.checkCompatibility();

    expect(result.disposition, RelayCompatibilityDisposition.compatible);
    expect(result.supports(RelayProtocolCapabilities.livePresence), isTrue);
    expect(result.supports('convoy-formations-v7'), isTrue);
    expect(result.supports('never-heard-of-it'), isFalse);
  });

  test('a relay with no compatibility document degrades to legacy', () async {
    final client = MockClient((request) async => http.Response('', 404));
    final api = HttpInternetRelayClient(
      configuration: InternetRelayConfiguration(
        baseUri: Uri.parse('https://relay.example/api'),
      ),
      client: client,
      clock: () => now,
    );

    final result = await api.checkCompatibility();

    expect(result.disposition, RelayCompatibilityDisposition.legacyCompatible);
    expect(result.canSynchronize, isTrue);
    expect(result.supports(RelayProtocolCapabilities.livePresence), isFalse);
  });

  group('presence over a version-skewed relay', () {
    Future<PreStartPresenceResult> presence({
      required List<String> serverCapabilities,
      Map<String, Object?> extraResponse = const {},
      List<Map<String, Object?>> positions = const [],
    }) async {
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/v1/compatibility')) {
          return http.Response(
            jsonEncode({
              'serverProtocol': 1,
              'minimumClientProtocol': 1,
              'maximumClientProtocol': 1,
              'capabilities': serverCapabilities,
              'requiredCapabilities': <String>[],
              'cacheSeconds': 300,
              'updateUrls': {'default': 'https://tailendcharlie.app'},
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'protocolVersion': 1,
            'ttlSeconds': 45,
            'positions': positions,
            ...extraResponse,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final api = HttpPreStartPresenceClient(
        configuration: InternetRelayConfiguration(
          baseUri: Uri.parse('https://relay.example/api'),
        ),
        client: client,
        clock: () => now,
      );
      return api.synchronizePreStartPresence(
        session: _session,
        position: null,
        clear: false,
      );
    }

    test('parses the phase, roster and legacy peer flags', () async {
      final result = await presence(
        serverCapabilities: RelayProtocolCapabilities.current.toList(),
        positions: [
          _rawPosition('bill', 'Bill', now, livePresence: false),
          _rawPosition('sam', 'Sam', now),
        ],
        extraResponse: {
          'phase': 'started',
          'members': [
            {
              'riderId': 'bill',
              'displayName': 'Bill',
              'role': 'rider',
              'joinedAt': now.toIso8601String(),
              'left': false,
            },
            {
              'riderId': 'gone',
              'displayName': 'Gone',
              'role': 'rider',
              'joinedAt': now.toIso8601String(),
              'left': true,
            },
          ],
        },
      );

      expect(result.phase, RidePresencePhase.started);
      expect(result.livePresenceServed, isTrue);
      expect(result.legacyPeerRiderIds, {'bill'});
      expect(result.roster.map((entry) => entry.riderId), ['bill', 'gone']);
      expect(result.roster.last.left, isTrue);
    });

    test('ignores unknown response and roster fields', () async {
      final result = await presence(
        serverCapabilities: RelayProtocolCapabilities.current.toList(),
        positions: [
          {
            ..._rawPosition('sam', 'Sam', now),
            'convoyPosition': 3,
            'futureField': {
              'nested': [1, 2, 3],
            },
          },
        ],
        extraResponse: {
          'phase': 'convoy',
          'members': [
            {
              'riderId': 'sam',
              'displayName': 'Sam',
              'role': 'tailEndCharlie',
              'joinedAt': now.toIso8601String(),
              'squadron': 'blue',
            },
            {'riderId': 'malformed'},
          ],
          'unexpectedTopLevel': true,
        },
      );

      expect(result.locations.single.riderId, 'sam');
      // An unrecognised phase degrades to unknown rather than failing.
      expect(result.phase, RidePresencePhase.unknown);
      expect(result.roster.map((entry) => entry.riderId), ['sam']);
    });

    test(
      'an older relay that only serves pre-start presence still works',
      () async {
        final result = await presence(
          serverCapabilities: const ['pre-start-presence-v1'],
          positions: [_rawPosition('sam', 'Sam', now)],
        );

        expect(result.locations.single.riderId, 'sam');
        expect(result.livePresenceServed, isFalse);
        expect(result.phase, RidePresencePhase.unknown);
        expect(result.roster, isEmpty);
      },
    );

    test('a relay with neither capability is named, not silent', () async {
      await expectLater(
        presence(serverCapabilities: const ['ride-start-v1']),
        throwsA(
          isA<InternetRelayException>()
              .having((error) => error.code, 'code', 'feature_unsupported')
              .having(
                (error) => error.message,
                'message',
                contains('does not support live rider positions'),
              ),
        ),
      );
    });
  });

  group('RelayClientDescriptor', () {
    test('reports an absent build version honestly', () {
      final descriptor = RelayClientDescriptor.current();

      // No workflow injects the dart-defines in this test environment, so the
      // descriptor must not invent a plausible-looking version.
      expect(descriptor.appVersion, RelayClientDescriptor.unknownVersion);
      expect(descriptor.appBuild, RelayClientDescriptor.unknownVersion);
      expect(descriptor.reportsAppVersion, isFalse);
      expect(descriptor.headers['x-tailendcharlie-app-version'], 'unknown');
      expect(descriptor.appVersion, isNot('1.0.1'));
      expect(descriptor.appBuild, isNot('22'));
    });

    test(
      'advertises the live-presence capability alongside the legacy one',
      () {
        final descriptor = RelayClientDescriptor.current();
        final advertised = descriptor.headers['x-tailendcharlie-capabilities']!
            .split(',');

        expect(advertised, contains('live-presence-v2'));
        expect(advertised, contains('pre-start-presence-v1'));
        expect(advertised, orderedEquals(List.of(advertised)..sort()));
      },
    );

    test('an explicit descriptor reports exactly what it was given', () {
      const descriptor = RelayClientDescriptor(
        protocolVersion: 1,
        platform: 'android',
        appVersion: '1.4.0',
        appBuild: '91',
        capabilities: {'ride-start-v1'},
      );

      expect(descriptor.reportsAppVersion, isTrue);
      expect(descriptor.headers, {
        'x-tailendcharlie-protocol': '1',
        'x-tailendcharlie-platform': 'android',
        'x-tailendcharlie-app-version': '1.4.0',
        'x-tailendcharlie-app-build': '91',
        'x-tailendcharlie-capabilities': 'ride-start-v1',
      });
    });
  });
}

class _HostNamingException implements Exception {
  const _HostNamingException();

  @override
  String toString() =>
      'HandshakeException: certificate verify failed for relay.internal.example:443';
}

const _validSignature =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, Object?> _rawEvent({
  String id = 'event-1',
  String type = 'statusMessage',
  int schemaVersion = 1,
  String signature = _validSignature,
  Map<String, Object?> extra = const {},
}) => {
  'schemaVersion': schemaVersion,
  'id': id,
  'rideId': _session.rideId,
  'deviceId': 'peer',
  'type': type,
  'priority': 'routine',
  'createdAt': '2026-07-25T10:00:00.000Z',
  'expiresAt': null,
  'payload': const {'message': 'OK'},
  'signature': signature,
  'acknowledged': false,
  ...extra,
};

Map<String, Object?> _rawPosition(
  String riderId,
  String displayName,
  DateTime recordedAt, {
  bool livePresence = true,
}) => {
  'riderId': riderId,
  'displayName': displayName,
  'role': 'rider',
  'motorcycleStyle': 'adventure',
  'riderColor': 'blue',
  'sample': {
    'position': {'latitude': 51.2, 'longitude': -2.4},
    'recordedAt': recordedAt.toIso8601String(),
    'accuracyMeters': 4,
    'speedMetersPerSecond': null,
    'headingDegrees': null,
  },
  'receivedAt': recordedAt.toIso8601String(),
  'expiresAt': recordedAt.add(const Duration(seconds: 45)).toIso8601String(),
  'livePresence': livePresence,
  'clientProtocol': 1,
};

final _session = RideSession(
  rideId: 'ride-skew',
  rideCode: '123456',
  inviteSecret: '0123456789abcdef0123456789abcdef',
  joinToken: 'test-join-token-0123456789',
  localRiderId: 'local',
  displayName: 'Oliver',
  role: RideRole.rider,
  joinedAt: DateTime.utc(2026, 7, 25, 9),
);

RideEvent _signedEvent({required String id, required String deviceId}) {
  final unsigned = RideEvent(
    id: id,
    rideId: _session.rideId,
    deviceId: deviceId,
    type: RideEventType.riderJoined,
    priority: EventPriority.routine,
    createdAt: DateTime.utc(2026, 7, 25, 10),
    payload: const {'displayName': 'Bill', 'role': 'rider'},
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
    signature: RideEventAuthenticator.sign(unsigned, _session.inviteSecret),
  );
}

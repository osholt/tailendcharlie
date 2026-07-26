import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_cursor_store.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/internet/internet_relay_worker.dart';
import 'package:ride_relay/relay/live_presence.dart';
import 'package:ride_relay/relay/relay_event_compatibility.dart';
import 'package:ride_relay/relay/relay_protocol.dart';
import 'package:ride_relay/relay/relay_queue.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';

/// Issue #128, both skew directions. Mixed tester builds are the normal case:
/// an older peer or relay must produce a **named** limitation, never a feature
/// that appears to have worked, and never a dropped batch or frame.
void main() {
  group('current client, older relay', () {
    test('the two capabilities are advertised and gated by name', () {
      expect(
        RelayProtocolCapabilities.current,
        containsAll([
          RelayProtocolCapabilities.tecRoleAssignment,
          RelayProtocolCapabilities.rejoinRouteSharing,
        ]),
      );
      final advertised = RelayClientDescriptor.current()
          .headers['x-tailendcharlie-capabilities']!
          .split(',');
      expect(advertised, contains('tec-role-assignment-v1'));
      expect(advertised, contains('rejoin-route-sharing-v1'));
    });

    test(
      'a relay that cannot carry them withholds and names the reason',
      () async {
        final eventStore = InMemoryEventStore();
        await eventStore.append(_event(id: 'core', createdAt: _base));
        await eventStore.append(
          _event(
            id: 'tec-request',
            type: RideEventType.tecRoleRequested,
            createdAt: _base.add(const Duration(seconds: 1)),
          ),
        );
        await eventStore.append(
          _event(
            id: 'tec-response',
            type: RideEventType.tecRoleResponded,
            createdAt: _base.add(const Duration(seconds: 2)),
          ),
        );
        await eventStore.append(
          _event(
            id: 'rejoin-share',
            type: RideEventType.rejoinRouteShared,
            createdAt: _base.add(const Duration(seconds: 3)),
          ),
        );
        // A relay that knows every capability except this issue's two.
        final api = _NegotiatedRelayApi(
          capabilities: RelayProtocolCapabilities.current
              .where(
                (capability) =>
                    capability != RelayProtocolCapabilities.tecRoleAssignment &&
                    capability != RelayProtocolCapabilities.rejoinRouteSharing,
              )
              .toSet(),
        );
        final worker = InternetRelayWorker(
          api: api,
          eventStore: eventStore,
          cursorStore: InMemoryInternetCursorStore(),
          pollInterval: const Duration(days: 1),
        );
        final synced = worker.statuses.firstWhere(
          (status) => status.phase == InternetRelayPhase.synced,
        );

        await worker.start(_session);
        final status = await synced.timeout(const Duration(seconds: 2));

        // All three are withheld; the ordinary event still goes.
        expect(api.uploadedEventIds, ['core']);
        expect(status.unsupportedUploadCount, 3);
        expect(
          status.limitations.map((limitation) => limitation.kind),
          contains(PresenceLimitationKind.uploadCapabilityMissing),
        );
        expect(
          worker.supportsCapability(
            RelayProtocolCapabilities.tecRoleAssignment,
          ),
          isFalse,
        );
        expect(
          worker.supportsCapability(
            RelayProtocolCapabilities.rejoinRouteSharing,
          ),
          isFalse,
        );
        // And they stay in the durable journal: offline-first is not sacrificed.
        expect(
          (await eventStore.eventsForRide(_session.rideId)).map((e) => e.id),
          containsAll(['tec-request', 'tec-response', 'rejoin-share']),
        );
        await worker.close();
      },
    );

    test('a relay that does carry them uploads them', () async {
      final eventStore = InMemoryEventStore();
      await eventStore.append(
        _event(
          id: 'tec-request',
          type: RideEventType.tecRoleRequested,
          createdAt: _base,
        ),
      );
      await eventStore.append(
        _event(
          id: 'rejoin-share',
          type: RideEventType.rejoinRouteShared,
          createdAt: _base.add(const Duration(seconds: 1)),
        ),
      );
      final api = _NegotiatedRelayApi(
        capabilities: RelayProtocolCapabilities.current,
      );
      final worker = InternetRelayWorker(
        api: api,
        eventStore: eventStore,
        cursorStore: InMemoryInternetCursorStore(),
        pollInterval: const Duration(days: 1),
      );
      final synced = worker.statuses.firstWhere(
        (status) => status.phase == InternetRelayPhase.synced,
      );

      await worker.start(_session);
      final status = await synced.timeout(const Duration(seconds: 2));

      expect(api.uploadedEventIds, ['tec-request', 'rejoin-share']);
      expect(status.unsupportedUploadCount, 0);
      expect(status.limitations, isEmpty);
      await worker.close();
    });

    test('the named limitations say what is lost and what still works', () {
      expect(
        PresenceLimitation.tecAssignmentUnsupportedByService.message,
        allOf(
          contains('too old'),
          contains('nobody has been asked'),
          contains('set the role themselves'),
        ),
      );
      expect(
        PresenceLimitation.tecAssignmentUnsupportedByPeer(
          riderId: 'bill',
          displayName: 'Bill',
        ).message,
        allOf(contains("Bill's app is older"), contains('until they update')),
      );
      expect(
        PresenceLimitation.rejoinSharingUnsupportedByService.message,
        allOf(
          contains('too old'),
          contains('still have it on this phone'),
          contains('leader will not see it'),
        ),
      );
      // No hostname, URL or raw error text in any of them.
      for (final message in [
        PresenceLimitation.tecAssignmentUnsupportedByService.message,
        PresenceLimitation.rejoinSharingUnsupportedByService.message,
      ]) {
        expect(message, isNot(contains('http')));
        expect(message, isNot(contains('://')));
      }
    });
  });

  group('older client, current relay', () {
    test('a build that does not know these types skips them per event', () {
      // The mechanism #99 built, exercised with the three names this issue adds
      // plus the ones a later issue might add. A build that predates a name sees
      // exactly this: a sanitised label, and the event skipped whole.
      for (final futureType in [
        'tecRoleRevoked',
        'rejoinRouteAcknowledged',
        'tecRoleDelegated',
      ]) {
        expect(
          describeUnsupportedRelayEvent(_rawEvent(type: futureType)),
          futureType,
          reason: futureType,
        );
      }
      // And this build reads its own three, so a newer peer's events are not
      // needlessly skipped.
      for (final type in [
        RideEventType.tecRoleRequested,
        RideEventType.tecRoleResponded,
        RideEventType.rejoinRouteShared,
      ]) {
        expect(
          describeUnsupportedRelayEvent(_rawEvent(type: type.name)),
          isNull,
        );
      }
    });

    test(
      'an internet batch mixing known and unknown types delivers the known ones',
      () async {
        final request = _signedEvent(
          id: 'tec-request',
          type: RideEventType.tecRoleRequested,
        );
        final client = MockClient(
          (_) async => http.Response(
            jsonEncode({
              'protocolVersion': 1,
              'cursor': 'cursor-1',
              'acceptedEventIds': <String>[],
              'events': [
                _rawEvent(id: 'future', type: 'tecRoleRevoked'),
                request.toJson(),
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
          clock: () => _base,
        );

        final result = await api.synchronize(
          session: _session,
          cursor: null,
          events: const [],
        );

        expect(result.events.map((event) => event.id), ['tec-request']);
        expect(result.cursor, 'cursor-1');
        expect(result.ignoredEventCount, 1);
        expect(result.ignoredEventTypes, {'tecRoleRevoked'});
        api.close();
      },
    );

    test(
      'a nearby frame mixing known and unknown types keeps the known ones',
      () {
        const protocol = RelayProtocol();
        final share = _signedEvent(
          id: 'rejoin-share',
          type: RideEventType.rejoinRouteShared,
        );
        // Signed by hand so the frame can carry a type this build cannot read
        // beside one it can - exactly what a newer peer sends, and what
        // RelayProtocol.encode cannot express because its API is typed.
        final bytes = _handSignedFrame([
          _queued(_rawEvent(id: 'future', type: 'rejoinRouteAcknowledged')),
          _queued(share.toJson()),
        ]);

        final decoded = protocol.decode(
          bytes,
          secret: _session.inviteSecret,
          expectedRideId: _session.rideId,
          now: _base.add(const Duration(minutes: 1)),
        );

        // The unknown event is skipped; the frame is not dropped and the new
        // type round-trips unchanged.
        expect(decoded.ignoredEventCount, 1);
        expect(decoded.events.single.event.id, 'rejoin-share');
        expect(
          decoded.events.single.event.type,
          RideEventType.rejoinRouteShared,
        );
      },
    );

    test('the new types survive an ordinary nearby round trip', () {
      const protocol = RelayProtocol();
      final request = _signedEvent(
        id: 'tec-request',
        type: RideEventType.tecRoleRequested,
      );
      final bytes = protocol.encode(
        RelayFrame(
          kind: RelayFrameKind.events,
          rideId: _session.rideId,
          senderId: 'peer',
          frameId: 'frame-2',
          sentAt: _base,
          events: [
            QueuedRelayEvent(
              event: request,
              firstSeenAt: _base,
              expiresAt: _base.add(const Duration(hours: 1)),
              hopCount: 0,
            ),
          ],
        ),
        secret: _session.inviteSecret,
      );

      final decoded = protocol.decode(
        bytes,
        secret: _session.inviteSecret,
        expectedRideId: _session.rideId,
        now: _base.add(const Duration(minutes: 1)),
      );

      expect(decoded.events.single.event.type, RideEventType.tecRoleRequested);
      expect(decoded.ignoredEventCount, 0);
    });
  });
}

/// A relay that negotiates a specific capability set and records what it was
/// actually offered.
class _NegotiatedRelayApi implements InternetRelayApi, RelayCompatibilityApi {
  _NegotiatedRelayApi({required this.capabilities});

  final Set<String> capabilities;
  final List<String> uploadedEventIds = [];
  var _cursor = 0;

  @override
  InternetRelayConfiguration get configuration =>
      InternetRelayConfiguration(baseUri: Uri.parse('https://relay.example'));

  @override
  Future<RelayCompatibilityResult> checkCompatibility() async =>
      RelayCompatibilityResult(
        disposition: RelayCompatibilityDisposition.compatible,
        serverProtocol: 1,
        minimumClientProtocol: 1,
        capabilities: capabilities,
        checkedAt: _base,
        validUntil: _base.add(const Duration(minutes: 5)),
      );

  @override
  Future<InternetSyncResult> synchronize({
    required RideSession session,
    required String? cursor,
    required List<RideEvent> events,
  }) async {
    _cursor += 1;
    uploadedEventIds.addAll(events.map((event) => event.id));
    return InternetSyncResult(
      cursor: 'cursor-$_cursor',
      acceptedEventIds: events.map((event) => event.id).toSet(),
      events: const [],
    );
  }

  @override
  void close() {}
}

final _base = DateTime.utc(2026, 7, 26, 10);

final _session = RideSession(
  rideId: 'ride-128-skew',
  rideCode: '123456',
  inviteSecret: '0123456789abcdef0123456789abcdef',
  joinToken: 'test-join-token-0123456789',
  localRiderId: 'local-device',
  displayName: 'Oliver',
  role: RideRole.rider,
  joinedAt: DateTime.utc(2026, 7, 26, 9),
);

const _validSignature =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, Object?> _rawEvent({
  String id = 'event-1',
  String type = 'statusMessage',
  int schemaVersion = 1,
}) => {
  'schemaVersion': schemaVersion,
  'id': id,
  'rideId': _session.rideId,
  'deviceId': 'peer',
  'type': type,
  'priority': 'routine',
  'createdAt': '2026-07-26T09:30:00.000Z',
  'expiresAt': null,
  'payload': const {'message': 'OK'},
  'signature': _validSignature,
  'acknowledged': false,
};

RideEvent _event({
  required String id,
  required DateTime createdAt,
  String deviceId = 'local-device',
  RideEventType type = RideEventType.statusMessage,
}) => _sign(
  RideEvent(
    id: id,
    rideId: _session.rideId,
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: createdAt,
    payload: const {'message': 'OK'},
    signature: '',
  ),
);

RideEvent _signedEvent({required String id, required RideEventType type}) =>
    _sign(
      RideEvent(
        id: id,
        rideId: _session.rideId,
        deviceId: 'peer',
        type: type,
        priority: EventPriority.important,
        createdAt: _base.subtract(const Duration(minutes: 30)),
        payload: const {'requestId': 'req-1'},
        signature: '',
      ),
    );

RideEvent _sign(RideEvent event) => RideEvent(
  id: event.id,
  rideId: event.rideId,
  deviceId: event.deviceId,
  type: event.type,
  priority: event.priority,
  createdAt: event.createdAt,
  expiresAt: event.expiresAt,
  payload: event.payload,
  signature: RideEventAuthenticator.sign(event, _session.inviteSecret),
);

Map<String, Object?> _queued(Map<String, Object?> event) => {
  'event': event,
  'firstSeenAt': _base.toUtc().toIso8601String(),
  'expiresAt': _base.add(const Duration(hours: 1)).toUtc().toIso8601String(),
  'hopCount': 0,
};

/// Builds a nearby frame the way a newer peer would, so it can carry an event
/// type this build has no enum value for. Mirrors `RelayProtocol`'s own HMAC over
/// canonical JSON; if that ever changes, this test fails loudly rather than
/// silently stopping exercising the skip path.
Uint8List _handSignedFrame(List<Map<String, Object?>> events) {
  final unsigned = <String, Object?>{
    'version': RelayProtocol.protocolVersion,
    'kind': 'events',
    'rideId': _session.rideId,
    'senderId': 'peer',
    'frameId': 'frame-1',
    'sentAt': _base.toUtc().toIso8601String(),
    'events': events,
  };
  final signature = Hmac(
    sha256,
    utf8.encode(_session.inviteSecret),
  ).convert(utf8.encode(_canonicalJson(unsigned))).toString();
  return Uint8List.fromList(
    utf8.encode(jsonEncode({...unsigned, 'authentication': signature})),
  );
}

String _canonicalJson(Object? value) {
  if (value is Map<Object?, Object?>) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}';
  }
  if (value is List<Object?>) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}

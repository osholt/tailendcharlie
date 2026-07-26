import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/relay/relay_protocol.dart';

/// The nearby transport had the same defect as the internet one: a single event
/// type from a newer peer made the whole authenticated frame decode fail, so
/// every known event beside it was discarded too.
void main() {
  const protocol = RelayProtocol();
  const secret = '0123456789abcdef0123456789abcdef';
  const rideId = 'ride-frame';
  final sentAt = DateTime.utc(2026, 7, 25, 12);
  final now = sentAt.add(const Duration(seconds: 1));

  Uint8List frame(List<Map<String, Object?>> events) {
    final unsigned = <String, Object?>{
      'version': 1,
      'kind': 'events',
      'rideId': rideId,
      'senderId': 'peer',
      'frameId': 'frame-1',
      'sentAt': sentAt.toIso8601String(),
      'events': [
        for (final event in events)
          {
            'event': event,
            'firstSeenAt': sentAt.toIso8601String(),
            'expiresAt': sentAt.add(const Duration(hours: 1)).toIso8601String(),
            'hopCount': 0,
          },
      ],
    };
    final signature = Hmac(
      sha256,
      utf8.encode(secret),
    ).convert(utf8.encode(_canonicalJson(unsigned))).toString();
    return Uint8List.fromList(
      utf8.encode(jsonEncode({...unsigned, 'authentication': signature})),
    );
  }

  test('keeps the known events in a frame beside a future event type', () {
    final decoded = protocol.decode(
      frame([
        _rawEvent(id: 'future', type: 'rideTeleported'),
        _rawEvent(id: 'known', type: 'riderJoined'),
        _rawEvent(id: 'future-schema', schemaVersion: 2),
        _rawEvent(id: 'known-position', type: 'riderLocationUpdated'),
      ]),
      secret: secret,
      expectedRideId: rideId,
      now: now,
    );

    expect(decoded.events.map((item) => item.event.id), [
      'known',
      'known-position',
    ]);
    expect(decoded.ignoredEventCount, 2);
    expect(decoded.events.first.event.type, RideEventType.riderJoined);
  });

  test('a frame of only future events is rejected without side effects', () {
    expect(
      () => protocol.decode(
        frame([_rawEvent(id: 'future', type: 'rideTeleported')]),
        secret: secret,
        expectedRideId: rideId,
        now: now,
      ),
      throwsA(isA<RelayProtocolException>()),
    );
  });

  test('an added envelope field is skipped rather than stripped', () {
    final decoded = protocol.decode(
      frame([
        _rawEvent(id: 'extra', extra: {'convoyId': 'c-1'}),
        _rawEvent(id: 'known', type: 'riderJoined'),
      ]),
      secret: secret,
      expectedRideId: rideId,
      now: now,
    );

    // Stripping the unknown field would either break the event signature or
    // admit a semantically different event, so the whole event is skipped.
    expect(decoded.events.map((item) => item.event.id), ['known']);
    expect(decoded.ignoredEventCount, 1);
  });

  test('a tampered frame still fails authentication', () {
    final bytes = frame([_rawEvent(id: 'known', type: 'riderJoined')]);
    final decodedJson = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    decodedJson['senderId'] = 'impostor';

    expect(
      () => protocol.decode(
        Uint8List.fromList(utf8.encode(jsonEncode(decodedJson))),
        secret: secret,
        expectedRideId: rideId,
        now: now,
      ),
      throwsA(isA<RelayProtocolException>()),
    );
  });

  test('a structurally invalid known event still fails the frame', () {
    expect(
      () => protocol.decode(
        frame([_rawEvent(id: 'broken', signature: 'nope')]),
        secret: secret,
        expectedRideId: rideId,
        now: now,
      ),
      throwsA(isA<RelayProtocolException>()),
    );
  });
}

const _validSignature =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, Object?> _rawEvent({
  required String id,
  String type = 'statusMessage',
  int schemaVersion = 1,
  String signature = _validSignature,
  Map<String, Object?> extra = const {},
}) => {
  'schemaVersion': schemaVersion,
  'id': id,
  'rideId': 'ride-frame',
  'deviceId': 'peer',
  'type': type,
  'priority': 'routine',
  'createdAt': '2026-07-25T12:00:00.000Z',
  'expiresAt': null,
  'payload': const {'displayName': 'Bill', 'role': 'rider'},
  'signature': signature,
  'acknowledged': false,
  ...extra,
};

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

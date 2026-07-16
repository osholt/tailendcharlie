import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';

void main() {
  test('verifies current signatures and rejects changed payloads', () {
    final unsigned = _event(signature: '');
    final signed = _event(
      signature: RideEventAuthenticator.sign(unsigned, _secret),
    );

    expect(RideEventAuthenticator.verify(signed, _secret), isTrue);
    expect(
      RideEventAuthenticator.verify(
        _event(signature: signed.signature, payload: const {'message': 'No'}),
        _secret,
      ),
      isFalse,
    );
  });

  test('keeps legacy event signatures readable', () {
    final unsigned = _event(signature: '');
    final legacyBody = jsonEncode({
      'id': unsigned.id,
      'rideId': unsigned.rideId,
      'deviceId': unsigned.deviceId,
      'type': unsigned.type.name,
      'priority': unsigned.priority.name,
      'createdAt': unsigned.createdAt.toUtc().toIso8601String(),
      'payload': unsigned.payload,
    });
    final legacySignature = Hmac(
      sha256,
      utf8.encode(_secret),
    ).convert(utf8.encode(legacyBody)).toString();

    expect(
      RideEventAuthenticator.verify(
        _event(signature: legacySignature),
        _secret,
      ),
      isTrue,
    );
  });
}

const _secret = '0123456789abcdef0123456789abcdef';

RideEvent _event({
  required String signature,
  Map<String, Object?> payload = const {'message': 'OK'},
}) => RideEvent(
  id: 'event-1',
  rideId: 'ride-alpha',
  deviceId: 'device-1',
  type: RideEventType.statusMessage,
  priority: EventPriority.routine,
  createdAt: DateTime.utc(2026, 7, 16, 10),
  payload: payload,
  signature: signature,
);

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../domain/ride_event.dart';

/// Signs the current event schema and verifies both it and the development
/// alpha's earlier event body so stored rides remain readable after upgrade.
class RideEventAuthenticator {
  const RideEventAuthenticator._();

  static String sign(RideEvent event, String secret) =>
      _digest(_canonicalV1Body(event), secret);

  static bool verify(RideEvent event, String secret) {
    final current = _constantTimeMatch(
      event.signature,
      _digest(_canonicalV1Body(event), secret),
    );
    final legacy = _constantTimeMatch(
      event.signature,
      _digest(_legacyBody(event), secret),
    );
    return (current | legacy) == 1;
  }

  static int _constantTimeMatch(String actual, String expected) {
    if (actual.length != expected.length) return 0;
    var difference = 0;
    for (var index = 0; index < expected.length; index += 1) {
      difference |= actual.codeUnitAt(index) ^ expected.codeUnitAt(index);
    }
    return difference == 0 ? 1 : 0;
  }

  static String _digest(String body, String secret) =>
      Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(body)).toString();

  static String _canonicalV1Body(RideEvent event) => jsonEncode({
    'schemaVersion': event.schemaVersion,
    'id': event.id,
    'rideId': event.rideId,
    'deviceId': event.deviceId,
    'type': event.type.name,
    'priority': event.priority.name,
    'createdAt': event.createdAt.toUtc().toIso8601String(),
    'expiresAt': event.expiresAt?.toUtc().toIso8601String(),
    'payload': event.payload,
  });

  static String _legacyBody(RideEvent event) => jsonEncode({
    'id': event.id,
    'rideId': event.rideId,
    'deviceId': event.deviceId,
    'type': event.type.name,
    'priority': event.priority.name,
    'createdAt': event.createdAt.toUtc().toIso8601String(),
    'payload': event.payload,
  });
}

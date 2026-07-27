import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import '../domain/ride_event.dart';

/// Signs the current event schema and verifies both it and the development
/// alpha's earlier event body so stored rides remain readable after upgrade.
class RideEventAuthenticator {
  const RideEventAuthenticator._();

  static String sign(RideEvent event, String secret) =>
      _digest(_canonicalV1Body(event), secret);

  /// Verdicts already reached, keyed by event identity.
  ///
  /// A [RideEvent] is immutable, so its verdict under a given secret never
  /// changes - but a ride journal is re-verified constantly: every reducer
  /// pass, every dashboard build. On a two-hour ride that is tens of thousands
  /// of events walked tens of thousands of times, which is what made the app
  /// unresponsive at the end of a ride (#165). Identity keying is what makes
  /// the memo safe: a forged event is a different object and is verified from
  /// scratch, so nothing can inherit another event's verdict. An [Expando]
  /// also releases its entry when the event is collected, so a removed ride
  /// leaves nothing behind.
  static final Expando<_Verdict> _verdicts = Expando<_Verdict>(
    'ride event signature verdict',
  );

  /// How many events have actually been authenticated, as opposed to answered
  /// from [_verdicts].
  ///
  /// Exposed because the cost this guards is invisible to a timing assertion on
  /// a shared CI machine but exact as a count: a journal walked ten times must
  /// authenticate each event once, not ten times.
  @visibleForTesting
  static int verificationsComputed = 0;

  static bool verify(RideEvent event, String secret) {
    final cached = _verdicts[event];
    if (cached != null && cached.secret == secret) return cached.verdict;
    verificationsComputed += 1;
    final verdict = _verifyUncached(event, secret);
    _verdicts[event] = _Verdict(secret, verdict);
    return verdict;
  }

  static bool _verifyUncached(RideEvent event, String secret) {
    if (_constantTimeMatch(
          event.signature,
          _digest(_canonicalV1Body(event), secret),
        ) ==
        1) {
      return true;
    }
    // Builds released before canonical ordering signed the same complete
    // envelope with insertion-ordered JSON. Keep those events readable during
    // the development-alpha migration.
    //
    // Stopping at the first body that matches costs a third as much for the
    // events almost every journal is made of. It reveals only which schema
    // version signed the event, which the event states in the clear anyway;
    // the comparison against each candidate digest stays constant-time, which
    // is the part that must not leak.
    if (_constantTimeMatch(
          event.signature,
          _digest(_transitionalV1Body(event), secret),
        ) ==
        1) {
      return true;
    }
    return _constantTimeMatch(
          event.signature,
          _digest(_legacyBody(event), secret),
        ) ==
        1;
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

  static String _canonicalV1Body(RideEvent event) =>
      _canonicalJson(_v1Map(event));

  static String _transitionalV1Body(RideEvent event) =>
      jsonEncode(_v1Map(event));

  static Map<String, Object?> _v1Map(RideEvent event) => {
    'schemaVersion': event.schemaVersion,
    'id': event.id,
    'rideId': event.rideId,
    'deviceId': event.deviceId,
    'type': event.type.name,
    'priority': event.priority.name,
    'createdAt': event.createdAt.toUtc().toIso8601String(),
    'expiresAt': event.expiresAt?.toUtc().toIso8601String(),
    'payload': event.payload,
  };

  static String _legacyBody(RideEvent event) => jsonEncode({
    'id': event.id,
    'rideId': event.rideId,
    'deviceId': event.deviceId,
    'type': event.type.name,
    'priority': event.priority.name,
    'createdAt': event.createdAt.toUtc().toIso8601String(),
    'payload': event.payload,
  });

  static String _canonicalJson(Object? value) {
    if (value is Map<Object?, Object?>) {
      final keys = value.keys.cast<String>().toList()..sort();
      return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}';
    }
    if (value is List<Object?>) {
      return '[${value.map(_canonicalJson).join(',')}]';
    }
    return jsonEncode(value);
  }
}

class _Verdict {
  const _Verdict(this.secret, this.verdict);

  final String secret;
  final bool verdict;
}

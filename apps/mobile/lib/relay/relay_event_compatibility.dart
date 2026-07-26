import '../domain/ride_event.dart';

const _relayEventEnvelopeFields = {
  'schemaVersion',
  'id',
  'rideId',
  'deviceId',
  'type',
  'priority',
  'createdAt',
  'expiresAt',
  'payload',
  'signature',
  'acknowledged',
};

/// Returns a sanitised label when a raw relay event cannot be understood by
/// this build, or null when it is safe to decode strictly.
///
/// "Cannot be understood" means a future event type, a future schema version or
/// an added envelope field. Anything else is a genuine protocol error, left for
/// strict decoding to reject.
///
/// The body is never mutated. An unknown event is skipped whole rather than
/// stripped down to the fields this build recognises, because the event
/// signature covers the whole envelope: stripping would either break
/// verification or, worse, admit a semantically different event.
///
/// Both transports share this so a newer peer cannot make either of them
/// discard a whole batch or frame — the failure that turns one unknown event
/// into a total, silent presence outage.
String? describeUnsupportedRelayEvent(Map<String, Object?> raw) {
  final schemaVersion = raw['schemaVersion'];
  if (schemaVersion is int && schemaVersion != 1) {
    return 'schema-v$schemaVersion';
  }
  final type = raw['type'];
  if (type is String &&
      !RideEventType.values.any((candidate) => candidate.name == type)) {
    return sanitiseRelayToken(type);
  }
  final hasUnknownField = raw.keys.any(
    (key) => !_relayEventEnvelopeFields.contains(key),
  );
  if (hasUnknownField) {
    return type is String ? '${sanitiseRelayToken(type)}+fields' : 'unknown';
  }
  return null;
}

/// Reduces an untrusted token to a short, alphanumeric label safe to show in a
/// diagnostic. Never returns caller-controlled punctuation, whitespace, URLs or
/// credential-looking text.
String sanitiseRelayToken(String value) {
  final filtered = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '');
  if (filtered.isEmpty) return 'unknown';
  return filtered.length <= 32 ? filtered : filtered.substring(0, 32);
}

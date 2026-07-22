import 'dart:convert';

enum RideEventType {
  rideCreated,
  riderJoined,
  riderLeft,
  roleChanged,
  rideStarted,
  markerStarted,
  markerPass,
  markerEnded,
  statusMessage,
  riderLocationUpdated,
  hazardReported,
  hazardCleared,
  routeDeviationChanged,
  routeAlertAcknowledged,
  routeRevisionChunk,
  routeRevisionPublished,
  routeCleared,
  ridePaused,
  rideResumed,
  rideEnded,
  iceInfoShared,
  iceInfoViewed,
}

enum EventPriority { routine, important, critical }

class RideEvent {
  const RideEvent({
    required this.id,
    required this.rideId,
    required this.deviceId,
    required this.type,
    required this.priority,
    required this.createdAt,
    required this.payload,
    required this.signature,
    this.expiresAt,
    this.acknowledged = false,
    this.schemaVersion = 1,
  });

  final String id;
  final String rideId;
  final String deviceId;
  final RideEventType type;
  final EventPriority priority;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final Map<String, Object?> payload;
  final String signature;
  final bool acknowledged;
  final int schemaVersion;

  RideEvent copyWith({bool? acknowledged}) => RideEvent(
    id: id,
    rideId: rideId,
    deviceId: deviceId,
    type: type,
    priority: priority,
    createdAt: createdAt,
    expiresAt: expiresAt,
    payload: payload,
    signature: signature,
    acknowledged: acknowledged ?? this.acknowledged,
    schemaVersion: schemaVersion,
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'rideId': rideId,
    'deviceId': deviceId,
    'type': type.name,
    'priority': priority.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'payload': payload,
    'signature': signature,
    'acknowledged': acknowledged,
  };

  factory RideEvent.fromJson(Map<String, Object?> json) {
    const allowedKeys = {
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
    if (json.keys.any((key) => !allowedKeys.contains(key))) {
      throw const FormatException('Event contains an unsupported field.');
    }
    final schemaVersion = _integer(json['schemaVersion'], 'schemaVersion');
    if (schemaVersion != 1) {
      throw const FormatException('Unsupported event schema version.');
    }
    final type = _enumValue(
      RideEventType.values,
      _string(json['type'], 'type', maximumLength: 48),
      'type',
    );
    final priority = _enumValue(
      EventPriority.values,
      _string(json['priority'], 'priority', maximumLength: 16),
      'priority',
    );
    final rawPayload = json['payload'];
    if (rawPayload is! Map<Object?, Object?>) {
      throw const FormatException('Event payload is invalid.');
    }
    if (rawPayload.keys.any((key) => key is! String)) {
      throw const FormatException('Event payload object is invalid.');
    }
    final payload = Map<String, Object?>.from(rawPayload);
    _validateJson(payload, depth: 0);
    final encoded = utf8.encode(jsonEncode(json));
    if (encoded.length > _maximumSerializedBytes) {
      throw const FormatException('Event exceeds the size limit.');
    }
    final acknowledged = json['acknowledged'];
    if (acknowledged != null && acknowledged is! bool) {
      throw const FormatException('Event acknowledgement is invalid.');
    }
    return RideEvent(
      schemaVersion: schemaVersion,
      id: _string(json['id'], 'id', maximumLength: 128),
      rideId: _string(json['rideId'], 'rideId', maximumLength: 128),
      deviceId: _string(json['deviceId'], 'deviceId', maximumLength: 128),
      type: type,
      priority: priority,
      createdAt: _date(json['createdAt'], 'createdAt'),
      expiresAt: switch (json['expiresAt']) {
        null => null,
        final Object value => _date(value, 'expiresAt'),
      },
      payload: payload,
      signature: _signature(json['signature']),
      acknowledged: acknowledged as bool? ?? false,
    );
  }

  static const _maximumSerializedBytes = 8 * 1024;
  static const _maximumJsonDepth = 16;
  static const _maximumCollectionEntries = 128;
  static final _signaturePattern = RegExp(r'^[0-9a-f]{64}$');

  static String _string(
    Object? value,
    String field, {
    required int maximumLength,
  }) {
    if (value is! String || value.isEmpty || value.length > maximumLength) {
      throw FormatException('Event $field is invalid.');
    }
    return value;
  }

  static int _integer(Object? value, String field) {
    if (value is! int) throw FormatException('Event $field is invalid.');
    return value;
  }

  static T _enumValue<T extends Enum>(
    List<T> values,
    String value,
    String field,
  ) {
    for (final candidate in values) {
      if (candidate.name == value) return candidate;
    }
    throw FormatException('Event $field is unsupported.');
  }

  static DateTime _date(Object? value, String field) {
    final text = _string(value, field, maximumLength: 40);
    if (!text.contains('T') ||
        (!text.endsWith('Z') && !RegExp(r'[+-]\d{2}:\d{2}$').hasMatch(text))) {
      throw FormatException('Event $field is invalid.');
    }
    try {
      return DateTime.parse(text).toLocal();
    } on FormatException {
      throw FormatException('Event $field is invalid.');
    }
  }

  static String _signature(Object? value) {
    final signature = _string(value, 'signature', maximumLength: 64);
    if (!_signaturePattern.hasMatch(signature)) {
      throw const FormatException('Event signature is invalid.');
    }
    return signature;
  }

  static void _validateJson(Object? value, {required int depth}) {
    if (depth > _maximumJsonDepth) {
      throw const FormatException('Event payload is too deeply nested.');
    }
    if (value == null || value is bool || value is String) return;
    if (value is num) {
      if (!value.isFinite) {
        throw const FormatException(
          'Event payload contains a non-finite number.',
        );
      }
      return;
    }
    if (value is List<Object?>) {
      if (value.length > _maximumCollectionEntries) {
        throw const FormatException('Event payload collection is too large.');
      }
      for (final item in value) {
        _validateJson(item, depth: depth + 1);
      }
      return;
    }
    if (value is Map<Object?, Object?>) {
      if (value.length > _maximumCollectionEntries ||
          value.keys.any((key) => key is! String || key.length > 128)) {
        throw const FormatException('Event payload object is invalid.');
      }
      for (final item in value.values) {
        _validateJson(item, depth: depth + 1);
      }
      return;
    }
    throw const FormatException('Event payload is invalid.');
  }
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../domain/rider_location.dart';
import '../domain/ride_event.dart';
import 'relay_queue.dart';
import 'relay_presence.dart';

enum RelayFrameKind { events, acknowledgement, presence }

class RelayFrame {
  const RelayFrame({
    required this.kind,
    required this.rideId,
    required this.senderId,
    required this.frameId,
    required this.sentAt,
    this.events = const [],
    this.acknowledgedEventIds = const [],
    this.presence,
  });

  final RelayFrameKind kind;
  final String rideId;
  final String senderId;
  final String frameId;
  final DateTime sentAt;
  final List<QueuedRelayEvent> events;
  final List<String> acknowledgedEventIds;
  final RelayPresenceUpdate? presence;
}

class RelayProtocolException implements Exception {
  const RelayProtocolException(this.message);

  final String message;

  @override
  String toString() => 'RelayProtocolException: $message';
}

/// Versioned, size-bounded and HMAC-authenticated wire format.
///
/// The frame stays under the 32 KiB cross-platform Nearby byte-payload limit.
/// It deliberately transports only small safety/event metadata, never GPX files
/// or unbounded location histories.
class RelayProtocol {
  const RelayProtocol();

  static const protocolVersion = 1;
  static const maxFrameBytes = 28 * 1024;
  static const maxEventsPerFrame = 12;
  static const maxAcknowledgementsPerFrame = 64;
  static const maxEventBytes = 8 * 1024;
  static const maxHops = maxRelayHops;
  static const maxFrameAge = Duration(minutes: 5);
  static const maxFutureSkew = Duration(minutes: 2);

  Uint8List encode(RelayFrame frame, {required String secret}) {
    _requireSecret(secret);
    if (frame.kind == RelayFrameKind.events &&
        (frame.events.isEmpty || frame.events.length > maxEventsPerFrame)) {
      throw const RelayProtocolException('Invalid event batch size');
    }
    if (frame.kind == RelayFrameKind.acknowledgement &&
        (frame.acknowledgedEventIds.isEmpty ||
            frame.acknowledgedEventIds.length > maxAcknowledgementsPerFrame)) {
      throw const RelayProtocolException('Invalid acknowledgement size');
    }
    if (frame.kind == RelayFrameKind.presence) {
      _validatePresence(frame);
    }
    for (final item in frame.events) {
      if (item.hopCount < 0 ||
          item.hopCount >= maxHops ||
          !item.expiresAt.isAfter(frame.sentAt) ||
          utf8.encode(jsonEncode(item.event.toJson())).length > maxEventBytes) {
        throw const RelayProtocolException('Invalid queued event');
      }
    }

    final unsigned = _unsignedMap(frame);
    final signature = _sign(unsigned, secret);
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode({...unsigned, 'authentication': signature})),
    );
    if (bytes.length > maxFrameBytes) {
      throw const RelayProtocolException('Frame exceeds byte limit');
    }
    return bytes;
  }

  RelayFrame decode(
    Uint8List bytes, {
    required String secret,
    required String expectedRideId,
    required DateTime now,
  }) {
    _requireSecret(secret);
    if (bytes.isEmpty || bytes.length > maxFrameBytes) {
      throw const RelayProtocolException('Invalid frame size');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on Object {
      throw const RelayProtocolException('Frame is not valid UTF-8 JSON');
    }
    if (decoded is! Map<Object?, Object?>) {
      throw const RelayProtocolException('Frame root must be an object');
    }
    final json = Map<String, Object?>.from(decoded);
    final authentication = json.remove('authentication');
    if (authentication is! String ||
        !_constantTimeEquals(authentication, _sign(json, secret))) {
      throw const RelayProtocolException('Authentication failed');
    }

    if (json['version'] != protocolVersion) {
      throw const RelayProtocolException('Unsupported protocol version');
    }
    final rideId = _boundedString(json['rideId'], 'rideId', 128);
    if (rideId != expectedRideId) {
      throw const RelayProtocolException('Frame belongs to another ride');
    }
    final senderId = _boundedString(json['senderId'], 'senderId', 128);
    final frameId = _boundedString(json['frameId'], 'frameId', 128);
    final sentAt = _date(json['sentAt'], 'sentAt');
    if (now.toUtc().difference(sentAt).abs() > maxFrameAge &&
        sentAt.isBefore(now.toUtc())) {
      throw const RelayProtocolException('Frame is stale');
    }
    if (sentAt.isAfter(now.toUtc().add(maxFutureSkew))) {
      throw const RelayProtocolException('Frame timestamp is in the future');
    }

    final kindName = _boundedString(json['kind'], 'kind', 32);
    final kind = switch (kindName) {
      'events' => RelayFrameKind.events,
      'acknowledgement' => RelayFrameKind.acknowledgement,
      'presence' => RelayFrameKind.presence,
      _ => throw const RelayProtocolException('Unknown frame kind'),
    };

    if (kind == RelayFrameKind.acknowledgement) {
      final rawIds = json['acknowledgedEventIds'];
      if (rawIds is! List<Object?> ||
          rawIds.isEmpty ||
          rawIds.length > maxAcknowledgementsPerFrame) {
        throw const RelayProtocolException('Invalid acknowledgement list');
      }
      return RelayFrame(
        kind: kind,
        rideId: rideId,
        senderId: senderId,
        frameId: frameId,
        sentAt: sentAt,
        acknowledgedEventIds: rawIds
            .map((id) => _boundedString(id, 'eventId', 128))
            .toSet()
            .toList(growable: false),
      );
    }
    if (kind == RelayFrameKind.presence) {
      final rawPresence = json['presence'];
      if (rawPresence is! Map<Object?, Object?>) {
        throw const RelayProtocolException('Invalid presence body');
      }
      final presence = Map<String, Object?>.from(rawPresence);
      final riderId = _boundedString(
        presence['riderId'],
        'presence riderId',
        128,
      );
      if (riderId != senderId) {
        throw const RelayProtocolException(
          'Presence rider does not match sender',
        );
      }
      final expiresAt = _date(presence['expiresAt'], 'presence expiresAt');
      if (!expiresAt.isAfter(now.toUtc()) ||
          expiresAt.isAfter(sentAt.add(const Duration(minutes: 5)))) {
        throw const RelayProtocolException('Invalid presence expiry');
      }
      final clear = presence['clear'];
      if (clear is! bool) {
        throw const RelayProtocolException('Invalid presence clear flag');
      }
      final rawPosition = presence['position'];
      if (clear != (rawPosition == null)) {
        throw const RelayProtocolException('Invalid presence payload');
      }
      RiderLocation? position;
      if (rawPosition != null) {
        if (rawPosition is! Map<Object?, Object?>) {
          throw const RelayProtocolException('Invalid presence position');
        }
        try {
          position = RiderLocation.fromJson(
            Map<String, Object?>.from(rawPosition),
          );
        } on Object {
          throw const RelayProtocolException('Invalid presence position');
        }
        if (position.riderId != riderId ||
            position.displayName.isEmpty ||
            position.displayName.length > 80 ||
            position.sample.accuracyMeters > 10000 ||
            position.sample.recordedAt.toUtc().isBefore(
              sentAt.subtract(const Duration(minutes: 5)),
            ) ||
            position.sample.recordedAt.toUtc().isAfter(
              sentAt.add(maxFutureSkew),
            )) {
          throw const RelayProtocolException('Invalid presence position');
        }
        position = RiderLocation(
          riderId: position.riderId,
          displayName: position.displayName,
          role: position.role,
          sample: position.sample,
          receivedAt: sentAt.toLocal(),
          motorcycleStyle: position.motorcycleStyle,
          riderColor: position.riderColor,
        );
      }
      return RelayFrame(
        kind: kind,
        rideId: rideId,
        senderId: senderId,
        frameId: frameId,
        sentAt: sentAt,
        presence: RelayPresenceUpdate(
          riderId: riderId,
          sentAt: sentAt,
          expiresAt: expiresAt,
          clear: clear,
          position: position,
        ),
      );
    }

    final rawEvents = json['events'];
    if (rawEvents is! List<Object?> ||
        rawEvents.isEmpty ||
        rawEvents.length > maxEventsPerFrame) {
      throw const RelayProtocolException('Invalid event list');
    }
    final events = <QueuedRelayEvent>[];
    for (final raw in rawEvents) {
      if (raw is! Map<Object?, Object?>) {
        throw const RelayProtocolException('Invalid queued event');
      }
      final queued = Map<String, Object?>.from(raw);
      final rawEvent = queued['event'];
      if (rawEvent is! Map<Object?, Object?> ||
          utf8.encode(jsonEncode(rawEvent)).length > maxEventBytes) {
        throw const RelayProtocolException('Invalid event body');
      }
      final RideEvent event;
      try {
        event = RideEvent.fromJson(Map<String, Object?>.from(rawEvent));
      } on Object {
        throw const RelayProtocolException('Event schema is invalid');
      }
      if (event.rideId != rideId) {
        throw const RelayProtocolException('Event ride does not match frame');
      }
      final firstSeenAt = _date(queued['firstSeenAt'], 'firstSeenAt');
      final expiresAt = _date(queued['expiresAt'], 'expiresAt');
      final hopCount = queued['hopCount'];
      if (hopCount is! int || hopCount < 0 || hopCount >= maxHops) {
        throw const RelayProtocolException('Invalid hop count');
      }
      if (!expiresAt.isAfter(now.toUtc())) {
        continue;
      }
      events.add(
        QueuedRelayEvent(
          event: event,
          firstSeenAt: firstSeenAt,
          expiresAt: expiresAt,
          hopCount: hopCount,
        ),
      );
    }
    if (events.isEmpty) {
      throw const RelayProtocolException('Frame contains no live events');
    }
    return RelayFrame(
      kind: kind,
      rideId: rideId,
      senderId: senderId,
      frameId: frameId,
      sentAt: sentAt,
      events: events,
    );
  }

  Map<String, Object?> _unsignedMap(RelayFrame frame) => {
    'version': protocolVersion,
    'kind': frame.kind.name,
    'rideId': frame.rideId,
    'senderId': frame.senderId,
    'frameId': frame.frameId,
    'sentAt': frame.sentAt.toUtc().toIso8601String(),
    if (frame.kind == RelayFrameKind.events)
      'events': frame.events
          .map(
            (item) => {
              'event': item.event.toJson(),
              'firstSeenAt': item.firstSeenAt.toUtc().toIso8601String(),
              'expiresAt': item.expiresAt.toUtc().toIso8601String(),
              'hopCount': item.hopCount,
            },
          )
          .toList(growable: false),
    if (frame.kind == RelayFrameKind.acknowledgement)
      'acknowledgedEventIds': frame.acknowledgedEventIds,
    if (frame.kind == RelayFrameKind.presence)
      'presence': {
        'riderId': frame.presence!.riderId,
        'expiresAt': frame.presence!.expiresAt.toUtc().toIso8601String(),
        'clear': frame.presence!.clear,
        if (frame.presence!.position case final position?)
          'position': position.toJson(),
      },
  };

  void _validatePresence(RelayFrame frame) {
    final presence = frame.presence;
    if (presence == null ||
        frame.events.isNotEmpty ||
        frame.acknowledgedEventIds.isNotEmpty ||
        presence.riderId != frame.senderId ||
        presence.riderId.isEmpty ||
        presence.riderId.length > 128 ||
        presence.clear != (presence.position == null) ||
        presence.expiresAt.isAfter(
          frame.sentAt.add(const Duration(minutes: 5)),
        ) ||
        !presence.expiresAt.isAfter(frame.sentAt) ||
        (presence.position != null &&
            presence.position!.riderId != presence.riderId)) {
      throw const RelayProtocolException('Invalid presence update');
    }
  }

  String _sign(Map<String, Object?> value, String secret) => Hmac(
    sha256,
    utf8.encode(secret),
  ).convert(utf8.encode(_canonicalJson(value))).toString();

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

  bool _constantTimeEquals(String left, String right) {
    var difference = left.length ^ right.length;
    final count = left.length < right.length ? left.length : right.length;
    for (var index = 0; index < count; index++) {
      difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
    }
    return difference == 0;
  }

  String _boundedString(Object? value, String name, int maxLength) {
    if (value is! String || value.isEmpty || value.length > maxLength) {
      throw RelayProtocolException('Invalid $name');
    }
    return value;
  }

  DateTime _date(Object? value, String name) {
    if (value is! String || value.length > 64) {
      throw RelayProtocolException('Invalid $name');
    }
    try {
      return DateTime.parse(value).toUtc();
    } on FormatException {
      throw RelayProtocolException('Invalid $name');
    }
  }

  void _requireSecret(String secret) {
    if (secret.length < 16 || secret.length > 512) {
      throw const RelayProtocolException('Ride secret is unavailable');
    }
  }
}

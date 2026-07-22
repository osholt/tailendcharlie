import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../domain/imported_route.dart';
import '../domain/ride_event.dart';
import '../domain/ride_role.dart';
import 'ride_event_authenticator.dart';
import 'ride_lifecycle.dart';

class RideRouteState {
  const RideRouteState({
    this.route,
    this.revisionId,
    this.revisionNumber = 0,
    this.changedAt,
    this.changedByRiderId,
    this.hasDecision = false,
  });

  final ImportedRoute? route;
  final String? revisionId;
  final int revisionNumber;
  final DateTime? changedAt;
  final String? changedByRiderId;
  final bool hasDecision;
}

class RideRouteEncoder {
  const RideRouteEncoder({this.maximumChunkCharacters = 3500});

  final int maximumChunkCharacters;

  EncodedRideRoute encode(ImportedRoute route) {
    final compressed = gzip.encode(utf8.encode(route.toJsonString()));
    final encoded = base64Url.encode(compressed);
    final chunks = <String>[];
    for (
      var offset = 0;
      offset < encoded.length;
      offset += maximumChunkCharacters
    ) {
      chunks.add(
        encoded.substring(
          offset,
          (offset + maximumChunkCharacters).clamp(0, encoded.length),
        ),
      );
    }
    return EncodedRideRoute(
      chunks: List.unmodifiable(chunks),
      sha256Digest: sha256.convert(compressed).toString(),
      compressedBytes: compressed.length,
    );
  }
}

class EncodedRideRoute {
  const EncodedRideRoute({
    required this.chunks,
    required this.sha256Digest,
    required this.compressedBytes,
  });

  final List<String> chunks;
  final String sha256Digest;
  final int compressedBytes;
}

class RideRouteReducer {
  const RideRouteReducer();

  RideRouteState fromEvents({
    required String rideId,
    required String inviteSecret,
    required Iterable<RideEvent> events,
  }) {
    final ordered =
        events
            .where(
              (event) =>
                  event.rideId == rideId &&
                  RideEventAuthenticator.verify(event, inviteSecret),
            )
            .toList(growable: false)
          ..sort(RideLifecycleReducer.compareEvents);
    final roles = <String, RideRole>{};
    final chunksByRevision = <String, Map<int, String>>{};
    final chunkAuthors = <String, String>{};
    final actions = <_RouteAction>[];

    for (final event in ordered) {
      switch (event.type) {
        case RideEventType.rideCreated:
        case RideEventType.riderJoined:
        case RideEventType.roleChanged:
          final role = _role(event.payload['role']);
          if (role != null) roles[event.deviceId] = role;
          break;
        case RideEventType.routeRevisionChunk:
          if (!_isCurrentLeaderEvent(event, roles)) continue;
          final revisionId = _string(event.payload['revisionId']);
          final index = event.payload['index'];
          final data = _string(event.payload['data']);
          if (revisionId == null ||
              index is! int ||
              index < 0 ||
              data == null ||
              data.length > 4096) {
            continue;
          }
          final previousAuthor = chunkAuthors[revisionId];
          if (previousAuthor != null && previousAuthor != event.deviceId) {
            continue;
          }
          chunkAuthors[revisionId] = event.deviceId;
          chunksByRevision.putIfAbsent(revisionId, () => {})[index] = data;
          break;
        case RideEventType.routeRevisionPublished:
          if (!_isCurrentLeaderEvent(event, roles)) continue;
          final action = _RouteAction.published(event);
          if (action != null) actions.add(action);
          break;
        case RideEventType.routeCleared:
          if (!_isCurrentLeaderEvent(event, roles)) continue;
          final revisionId = _string(event.payload['revisionId']);
          final revisionNumber = event.payload['revisionNumber'];
          if (revisionId == null ||
              revisionNumber is! int ||
              revisionNumber < 1) {
            continue;
          }
          actions.add(
            _RouteAction(
              event: event,
              revisionId: revisionId,
              revisionNumber: revisionNumber,
              cleared: true,
            ),
          );
          break;
        case RideEventType.riderLeft:
        case RideEventType.rideStarted:
        case RideEventType.markerStarted:
        case RideEventType.markerPass:
        case RideEventType.markerEnded:
        case RideEventType.statusMessage:
        case RideEventType.riderLocationUpdated:
        case RideEventType.hazardReported:
        case RideEventType.hazardCleared:
        case RideEventType.routeDeviationChanged:
        case RideEventType.routeAlertAcknowledged:
        case RideEventType.ridePaused:
        case RideEventType.rideResumed:
        case RideEventType.rideEnded:
        case RideEventType.iceInfoShared:
        case RideEventType.iceInfoViewed:
          break;
      }
    }

    var state = const RideRouteState();
    for (final action in actions) {
      if (action.revisionNumber < state.revisionNumber) continue;
      if (action.cleared) {
        state = RideRouteState(
          revisionId: action.revisionId,
          revisionNumber: action.revisionNumber,
          changedAt: action.event.createdAt,
          changedByRiderId: action.event.deviceId,
          hasDecision: true,
        );
        continue;
      }
      final route = _decodeRoute(
        action,
        chunksByRevision[action.revisionId],
        chunkAuthors[action.revisionId],
      );
      if (route == null) continue;
      state = RideRouteState(
        route: route,
        revisionId: action.revisionId,
        revisionNumber: action.revisionNumber,
        changedAt: action.event.createdAt,
        changedByRiderId: action.event.deviceId,
        hasDecision: true,
      );
    }
    return state;
  }

  static ImportedRoute? _decodeRoute(
    _RouteAction action,
    Map<int, String>? chunks,
    String? chunkAuthor,
  ) {
    if (chunks == null ||
        chunkAuthor != action.event.deviceId ||
        chunks.length != action.chunkCount) {
      return null;
    }
    final buffer = StringBuffer();
    for (var index = 0; index < action.chunkCount; index += 1) {
      final value = chunks[index];
      if (value == null) return null;
      buffer.write(value);
    }
    try {
      final compressed = base64Url.decode(buffer.toString());
      if (compressed.length != action.compressedBytes ||
          sha256.convert(compressed).toString() != action.sha256Digest) {
        return null;
      }
      return ImportedRoute.fromJsonString(
        utf8.decode(gzip.decode(compressed), allowMalformed: false),
      );
    } on Object {
      return null;
    }
  }

  static bool _isCurrentLeaderEvent(
    RideEvent event,
    Map<String, RideRole> roles,
  ) =>
      roles[event.deviceId] == RideRole.lead &&
      event.payload['leaderRiderId'] == event.deviceId;

  static RideRole? _role(Object? value) {
    if (value is! String) return null;
    try {
      return RideRole.values.byName(value);
    } on ArgumentError {
      return null;
    }
  }

  static String? _string(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
}

class _RouteAction {
  const _RouteAction({
    required this.event,
    required this.revisionId,
    required this.revisionNumber,
    required this.cleared,
    this.chunkCount = 0,
    this.compressedBytes = 0,
    this.sha256Digest = '',
  });

  static _RouteAction? published(RideEvent event) {
    final revisionId = RideRouteReducer._string(event.payload['revisionId']);
    final revisionNumber = event.payload['revisionNumber'];
    final chunkCount = event.payload['chunkCount'];
    final compressedBytes = event.payload['compressedBytes'];
    final digest = RideRouteReducer._string(event.payload['sha256']);
    if (revisionId == null ||
        revisionNumber is! int ||
        revisionNumber < 1 ||
        chunkCount is! int ||
        chunkCount < 1 ||
        chunkCount > 5000 ||
        compressedBytes is! int ||
        compressedBytes < 1 ||
        digest == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      return null;
    }
    return _RouteAction(
      event: event,
      revisionId: revisionId,
      revisionNumber: revisionNumber,
      cleared: false,
      chunkCount: chunkCount,
      compressedBytes: compressedBytes,
      sha256Digest: digest,
    );
  }

  final RideEvent event;
  final String revisionId;
  final int revisionNumber;
  final bool cleared;
  final int chunkCount;
  final int compressedBytes;
  final String sha256Digest;
}

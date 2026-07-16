import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../domain/ride_event.dart';
import '../domain/ride_session.dart';

class InternetRelayConfiguration {
  const InternetRelayConfiguration({
    required this.baseUri,
    this.headerTimeout = const Duration(seconds: 8),
    this.bodyTimeout = const Duration(seconds: 15),
    this.maximumRequestBytes = 64 * 1024,
    this.maximumResponseBytes = 128 * 1024,
    this.maximumEventBytes = 8 * 1024,
    this.maximumUploadEvents = 20,
    this.maximumDownloadEvents = 100,
  });

  factory InternetRelayConfiguration.fromEnvironment() {
    const value = String.fromEnvironment('RIDE_RELAY_API_BASE_URL');
    if (value.trim().isEmpty) {
      return const InternetRelayConfiguration(baseUri: null);
    }
    return InternetRelayConfiguration(baseUri: Uri.tryParse(value.trim()));
  }

  final Uri? baseUri;
  final Duration headerTimeout;
  final Duration bodyTimeout;
  final int maximumRequestBytes;
  final int maximumResponseBytes;
  final int maximumEventBytes;
  final int maximumUploadEvents;
  final int maximumDownloadEvents;

  bool get isConfigured => configurationError == null && baseUri != null;

  String? get configurationError {
    final uri = baseUri;
    if (uri == null) return 'No internet relay endpoint is configured.';
    if (uri.scheme != 'https' || uri.host.isEmpty) {
      return 'Internet relay requires an absolute HTTPS endpoint.';
    }
    if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) {
      return 'Internet relay endpoint cannot contain credentials, a query, or a fragment.';
    }
    return null;
  }
}

class InternetSyncResult {
  const InternetSyncResult({
    required this.cursor,
    required this.acceptedEventIds,
    required this.events,
  });

  final String cursor;
  final Set<String> acceptedEventIds;
  final List<RideEvent> events;
}

class InternetRelayException implements Exception {
  const InternetRelayException(
    this.message, {
    this.retryable = false,
    this.unauthorized = false,
    this.retryAfter,
    this.statusCode,
  });

  final String message;
  final bool retryable;
  final bool unauthorized;
  final Duration? retryAfter;
  final int? statusCode;

  @override
  String toString() => 'InternetRelayException: $message';
}

abstract interface class InternetRelayApi {
  InternetRelayConfiguration get configuration;

  Future<InternetSyncResult> synchronize({
    required RideSession session,
    required String? cursor,
    required List<RideEvent> events,
  });

  void close();
}

class HttpInternetRelayClient implements InternetRelayApi {
  factory HttpInternetRelayClient({
    required InternetRelayConfiguration configuration,
    required http.Client client,
  }) => HttpInternetRelayClient._(configuration, client);

  HttpInternetRelayClient._(this.configuration, this._client);

  @override
  final InternetRelayConfiguration configuration;
  final http.Client _client;

  @override
  Future<InternetSyncResult> synchronize({
    required RideSession session,
    required String? cursor,
    required List<RideEvent> events,
  }) async {
    final configurationError = configuration.configurationError;
    if (configurationError != null) {
      throw InternetRelayException(configurationError);
    }
    if (session.inviteSecret.length < 16) {
      throw const InternetRelayException(
        'Internet relay requires an authenticated ride invitation.',
      );
    }
    if (session.rideId.isEmpty ||
        session.rideId.length > 128 ||
        session.localRiderId.isEmpty ||
        session.localRiderId.length > 128) {
      throw const InternetRelayException('Ride or device identity is invalid.');
    }
    if (events.length > configuration.maximumUploadEvents) {
      throw const InternetRelayException('Upload event limit exceeded.');
    }
    if (cursor != null && cursor.length > 512) {
      throw const InternetRelayException('Stored cursor is invalid.');
    }
    for (final event in events) {
      _validateEventForRide(event, session.rideId);
      if (utf8.encode(jsonEncode(event.toJson())).length >
          configuration.maximumEventBytes) {
        throw InternetRelayException(
          'Event ${event.id} exceeds the size limit.',
        );
      }
    }

    final bodyBytes = utf8.encode(
      jsonEncode({
        'protocolVersion': 1,
        'deviceId': session.localRiderId,
        'cursor': cursor,
        'events': events.map((event) => event.toJson()).toList(growable: false),
      }),
    );
    if (bodyBytes.length > configuration.maximumRequestBytes) {
      throw const InternetRelayException(
        'Sync request exceeds the size limit.',
      );
    }

    final request = http.Request('POST', _syncUri(session.rideId))
      ..followRedirects = false
      ..headers.addAll({
        'accept': 'application/json',
        'authorization': 'Bearer ${_rideToken(session)}',
        'content-type': 'application/json',
        'idempotency-key': _idempotencyKey(bodyBytes),
        'x-ride-relay-device': session.localRiderId,
      })
      ..bodyBytes = bodyBytes;

    late http.StreamedResponse response;
    try {
      response = await _client
          .send(request)
          .timeout(configuration.headerTimeout);
    } on TimeoutException {
      throw const InternetRelayException(
        'Internet relay timed out before receiving response headers.',
        retryable: true,
      );
    } on http.ClientException catch (error) {
      throw InternetRelayException(
        'Internet relay network error: ${error.message}',
        retryable: true,
      );
    }

    late Uint8List responseBytes;
    try {
      responseBytes = await _readBoundedResponse(
        response,
      ).timeout(configuration.bodyTimeout);
    } on TimeoutException {
      throw const InternetRelayException(
        'Internet relay response body timed out.',
        retryable: true,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _failureForResponse(response);
    }
    final contentType = response.headers['content-type']?.toLowerCase();
    if (contentType == null || !contentType.contains('application/json')) {
      throw const InternetRelayException(
        'Internet relay returned a non-JSON response.',
      );
    }

    try {
      final decoded = jsonDecode(utf8.decode(responseBytes));
      if (decoded is! Map) {
        throw const FormatException('Response is not an object.');
      }
      final json = Map<String, Object?>.from(decoded);
      if ((json['protocolVersion'] as num?)?.toInt() != 1) {
        throw const FormatException('Unsupported protocol version.');
      }
      final responseCursor = json['cursor'];
      if (responseCursor is! String || responseCursor.length > 512) {
        throw const FormatException('Invalid response cursor.');
      }
      final acceptedValues = json['acceptedEventIds'];
      final eventValues = json['events'];
      if (acceptedValues is! List || eventValues is! List) {
        throw const FormatException('Missing response event arrays.');
      }
      if (acceptedValues.length > configuration.maximumUploadEvents ||
          eventValues.length > configuration.maximumDownloadEvents) {
        throw const FormatException('Response event limit exceeded.');
      }
      final uploadedIds = events.map((event) => event.id).toSet();
      final acceptedIds = acceptedValues.map((value) {
        if (value is! String ||
            value.length > 128 ||
            !uploadedIds.contains(value)) {
          throw const FormatException('Invalid accepted event ID.');
        }
        return value;
      }).toSet();
      final remoteEvents = eventValues
          .map((value) {
            if (value is! Map) {
              throw const FormatException('Invalid event object.');
            }
            final raw = Map<String, Object?>.from(value);
            if (utf8.encode(jsonEncode(raw)).length >
                configuration.maximumEventBytes) {
              throw const FormatException(
                'Response event exceeds the size limit.',
              );
            }
            final event = RideEvent.fromJson(raw);
            _validateEventForRide(event, session.rideId);
            return event;
          })
          .toList(growable: false);
      return InternetSyncResult(
        cursor: responseCursor,
        acceptedEventIds: acceptedIds,
        events: remoteEvents,
      );
    } on InternetRelayException {
      rethrow;
    } on Object catch (error) {
      throw InternetRelayException('Invalid internet relay response: $error');
    }
  }

  Future<Uint8List> _readBoundedResponse(http.StreamedResponse response) async {
    final declaredLength = response.contentLength;
    if (declaredLength != null &&
        declaredLength > configuration.maximumResponseBytes) {
      throw const InternetRelayException(
        'Internet relay response exceeds the size limit.',
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > configuration.maximumResponseBytes) {
        throw const InternetRelayException(
          'Internet relay response exceeds the size limit.',
        );
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  InternetRelayException _failureForResponse(http.StreamedResponse response) {
    final status = response.statusCode;
    final unauthorized = status == 401 || status == 403;
    final retryable = status == 408 || status == 429 || status >= 500;
    return InternetRelayException(
      unauthorized
          ? 'Internet relay rejected this ride credential.'
          : 'Internet relay returned HTTP $status.',
      retryable: retryable,
      unauthorized: unauthorized,
      retryAfter: status == 429 ? _parseRetryAfter(response.headers) : null,
      statusCode: status,
    );
  }

  Duration? _parseRetryAfter(Map<String, String> headers) {
    final seconds = int.tryParse(headers['retry-after'] ?? '');
    if (seconds == null || seconds < 0) return null;
    return Duration(seconds: seconds.clamp(0, 300));
  }

  Uri _syncUri(String rideId) {
    final base = configuration.baseUri!;
    final baseText = base.toString().endsWith('/')
        ? base.toString().substring(0, base.toString().length - 1)
        : base.toString();
    return Uri.parse(
      '$baseText/v1/rides/${Uri.encodeComponent(rideId)}/events:sync',
    );
  }

  String _rideToken(RideSession session) {
    final digest = Hmac(
      sha256,
      utf8.encode(session.inviteSecret),
    ).convert(utf8.encode('ride-relay-internet-token-v1\n${session.rideId}'));
    return 'rr1_${base64Url.encode(digest.bytes).replaceAll('=', '')}';
  }

  String _idempotencyKey(List<int> bodyBytes) =>
      'rr1-${base64Url.encode(sha256.convert(bodyBytes).bytes).replaceAll('=', '')}';

  void _validateEventForRide(RideEvent event, String rideId) {
    if (event.schemaVersion != 1 ||
        event.rideId != rideId ||
        event.id.isEmpty ||
        event.id.length > 128 ||
        event.deviceId.isEmpty ||
        event.deviceId.length > 128 ||
        event.signature.isEmpty ||
        event.signature.length > 256) {
      throw InternetRelayException(
        'Event ${event.id} is invalid for this ride.',
      );
    }
  }

  @override
  void close() => _client.close();
}

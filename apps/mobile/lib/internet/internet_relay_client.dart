import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
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

abstract final class RelayProtocolCapabilities {
  static const rideStart = 'ride-start-v1';
  static const membership = 'membership-v1';
  static const routeRevisions = 'route-revisions-v1';

  static const current = {rideStart, membership, routeRevisions};
}

class RelayClientDescriptor {
  const RelayClientDescriptor({
    required this.protocolVersion,
    required this.platform,
    required this.appVersion,
    required this.appBuild,
    required this.capabilities,
  });

  factory RelayClientDescriptor.current() => RelayClientDescriptor(
    protocolVersion: 1,
    platform: defaultTargetPlatform.name,
    appVersion: const String.fromEnvironment(
      'RIDE_RELAY_APP_VERSION',
      defaultValue: '1.0.1',
    ),
    appBuild: const String.fromEnvironment(
      'RIDE_RELAY_APP_BUILD',
      defaultValue: '22',
    ),
    capabilities: RelayProtocolCapabilities.current,
  );

  final int protocolVersion;
  final String platform;
  final String appVersion;
  final String appBuild;
  final Set<String> capabilities;

  Map<String, String> get headers => {
    'x-tailendcharlie-protocol': '$protocolVersion',
    'x-tailendcharlie-platform': platform,
    'x-tailendcharlie-app-version': appVersion,
    'x-tailendcharlie-app-build': appBuild,
    'x-tailendcharlie-capabilities': (capabilities.toList()..sort()).join(','),
  };
}

enum RelayCompatibilityDisposition {
  compatible,
  legacyCompatible,
  updateRequired,
  serverUpgradeRequired,
  temporarilyUnavailable,
}

class RelayCompatibilityResult {
  const RelayCompatibilityResult({
    required this.disposition,
    required this.serverProtocol,
    required this.minimumClientProtocol,
    required this.capabilities,
    required this.checkedAt,
    required this.validUntil,
    this.message,
    this.updateUri,
  });

  final RelayCompatibilityDisposition disposition;
  final int serverProtocol;
  final int minimumClientProtocol;
  final Set<String> capabilities;
  final DateTime checkedAt;
  final DateTime validUntil;
  final String? message;
  final Uri? updateUri;

  bool get canSynchronize =>
      disposition == RelayCompatibilityDisposition.compatible ||
      disposition == RelayCompatibilityDisposition.legacyCompatible;

  bool supports(String capability) => capabilities.contains(capability);
}

abstract interface class RelayCompatibilityApi {
  Future<RelayCompatibilityResult> checkCompatibility();
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
    this.code,
    this.actionUrl,
  });

  final String message;
  final bool retryable;
  final bool unauthorized;
  final Duration? retryAfter;
  final int? statusCode;
  final String? code;
  final Uri? actionUrl;

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

/// The short-lived server directory that turns a six-digit ride code into the
/// ride credentials needed by the authenticated relays.
abstract interface class RideCodeDirectory {
  Future<void> register(RideSession session);

  Future<RideCodeCredentials> resolve(String rideCode, {String? joinToken});

  void close();
}

class RideCodeCredentials {
  const RideCodeCredentials({
    required this.rideId,
    required this.rideCode,
    required this.inviteSecret,
    required this.joinToken,
  });

  final String rideId;
  final String rideCode;
  final String inviteSecret;

  /// So a rider who joins can also re-share a fully hardened invite later,
  /// not just the ride creator.
  final String joinToken;
}

class RideCodeDirectoryException implements Exception {
  const RideCodeDirectoryException(
    this.message, {
    this.codeConflict = false,
    this.retryable = false,
  });

  final String message;
  final bool codeConflict;
  final bool retryable;

  @override
  String toString() => 'RideCodeDirectoryException: $message';
}

class HttpRideCodeDirectory implements RideCodeDirectory {
  factory HttpRideCodeDirectory.fromEnvironment() => HttpRideCodeDirectory(
    configuration: InternetRelayConfiguration.fromEnvironment(),
    client: http.Client(),
  );

  factory HttpRideCodeDirectory({
    required InternetRelayConfiguration configuration,
    required http.Client client,
    RelayClientDescriptor? clientDescriptor,
    DateTime Function()? clock,
  }) => HttpRideCodeDirectory._(
    configuration,
    client,
    clientDescriptor ?? RelayClientDescriptor.current(),
    clock ?? DateTime.now,
  );

  HttpRideCodeDirectory._(
    this.configuration,
    this._client,
    this._clientDescriptor,
    this._clock,
  );

  final InternetRelayConfiguration configuration;
  final http.Client _client;
  final RelayClientDescriptor _clientDescriptor;
  final DateTime Function() _clock;
  RelayCompatibilityResult? _cachedCompatibility;

  @override
  Future<void> register(RideSession session) async {
    _validateConfiguration();
    _validateSession(session);
    await _ensureCompatibility();
    final response = await _send(
      http.Request('PUT', _joinCodeUri(session.rideCode))
        ..followRedirects = false
        ..headers.addAll({
          'accept': 'application/json',
          'authorization': 'Bearer ${_rideBearerToken(session)}',
          'content-type': 'application/json',
          ..._clientDescriptor.headers,
        })
        ..body = jsonEncode({
          'rideId': session.rideId,
          'inviteSecret': session.inviteSecret,
          'resolveToken': session.joinToken,
        }),
    );
    if (response.statusCode == 204) return;
    throw _directoryFailure(response.statusCode);
  }

  @override
  Future<RideCodeCredentials> resolve(
    String rideCode, {
    String? joinToken,
  }) async {
    _validateConfiguration();
    await _ensureCompatibility();
    final normalizedCode = _normaliseCode(rideCode);
    final response = await _send(
      http.Request('GET', _joinCodeUri(normalizedCode))
        ..followRedirects = false
        ..headers['accept'] = 'application/json'
        ..headers.addAll(_clientDescriptor.headers)
        ..headers.addAll(
          joinToken == null ? {} : {'x-ride-relay-join-token': joinToken},
        ),
    );
    final body = await _readBoundedResponse(response);
    if (response.statusCode != 200) {
      throw _directoryFailure(response.statusCode);
    }
    final contentType = response.headers['content-type']?.toLowerCase();
    if (contentType == null || !contentType.contains('application/json')) {
      throw const RideCodeDirectoryException(
        'Ride code service returned an invalid response.',
      );
    }
    try {
      final value = jsonDecode(utf8.decode(body));
      if (value is! Map) {
        throw const FormatException('Response is not an object.');
      }
      final json = Map<String, Object?>.from(value);
      final rideId = json['rideId'];
      final returnedCode = json['rideCode'];
      final secret = json['inviteSecret'];
      final returnedJoinToken = json['resolveToken'];
      if (rideId is! String ||
          rideId.isEmpty ||
          rideId.length > 128 ||
          returnedCode is! String ||
          returnedCode != normalizedCode ||
          secret is! String ||
          secret.length < 16 ||
          secret.length > 512 ||
          returnedJoinToken is! String ||
          returnedJoinToken.length < 16 ||
          returnedJoinToken.length > 128) {
        throw const FormatException('Response fields are invalid.');
      }
      return RideCodeCredentials(
        rideId: rideId,
        rideCode: returnedCode,
        inviteSecret: secret,
        joinToken: returnedJoinToken,
      );
    } on FormatException {
      throw const RideCodeDirectoryException(
        'Ride code service returned an invalid response.',
      );
    } on Object catch (error) {
      throw RideCodeDirectoryException(
        'Ride code service returned an invalid response: $error',
      );
    }
  }

  Future<http.StreamedResponse> _send(http.BaseRequest request) async {
    try {
      return await _client.send(request).timeout(configuration.headerTimeout);
    } on TimeoutException {
      throw const RideCodeDirectoryException(
        'Ride code service timed out. Check your connection and try again.',
        retryable: true,
      );
    } on http.ClientException {
      throw const RideCodeDirectoryException(
        'Ride code service is temporarily unavailable. Check your connection and try again.',
        retryable: true,
      );
    }
  }

  Future<void> _ensureCompatibility() async {
    try {
      final result = await _fetchCompatibility(
        configuration: configuration,
        client: _client,
        descriptor: _clientDescriptor,
        clock: _clock,
        cached: _cachedCompatibility,
      );
      _cachedCompatibility = result;
      if (result.canSynchronize) return;
      throw RideCodeDirectoryException(
        result.message ?? 'This app and the ride service are not compatible.',
        retryable:
            result.disposition ==
            RelayCompatibilityDisposition.temporarilyUnavailable,
      );
    } on InternetRelayException catch (error) {
      throw RideCodeDirectoryException(
        error.message,
        retryable: error.retryable,
      );
    }
  }

  Future<Uint8List> _readBoundedResponse(http.StreamedResponse response) async {
    final declaredLength = response.contentLength;
    if (declaredLength != null && declaredLength > 2048) {
      throw const RideCodeDirectoryException(
        'Ride code service returned an oversized response.',
      );
    }
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.stream.timeout(
        configuration.bodyTimeout,
      )) {
        if (bytes.length + chunk.length > 2048) {
          throw const RideCodeDirectoryException(
            'Ride code service returned an oversized response.',
          );
        }
        bytes.add(chunk);
      }
    } on TimeoutException {
      throw const RideCodeDirectoryException(
        'Ride code service timed out. Check your connection and try again.',
        retryable: true,
      );
    }
    return bytes.takeBytes();
  }

  void _validateConfiguration() {
    final error = configuration.configurationError;
    if (error != null) {
      throw const RideCodeDirectoryException(
        'Joining by ride code needs the Tail End Charlie service to be connected.',
      );
    }
  }

  void _validateSession(RideSession session) {
    _normaliseCode(session.rideCode);
    if (session.rideId.isEmpty ||
        session.rideId.length > 128 ||
        session.inviteSecret.length < 16 ||
        session.joinToken.length < 16) {
      throw const RideCodeDirectoryException(
        'This ride cannot be shared with a code.',
      );
    }
  }

  RideCodeDirectoryException _directoryFailure(int status) => switch (status) {
    400 => const RideCodeDirectoryException(
      'Enter a valid six-digit ride code.',
    ),
    404 => const RideCodeDirectoryException(
      'That ride code is not active. Check it with the ride lead.',
    ),
    409 => const RideCodeDirectoryException(
      'That ride code is already in use. A new code will be chosen.',
      codeConflict: true,
    ),
    429 => const RideCodeDirectoryException(
      'Too many ride-code attempts. Please wait a moment and try again.',
      retryable: true,
    ),
    401 || 403 => const RideCodeDirectoryException(
      'Ride code service rejected this ride.',
    ),
    _ => RideCodeDirectoryException(
      'Ride code service returned HTTP $status.',
      retryable: status >= 500,
    ),
  };

  String _normaliseCode(String value) {
    final code = value.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      throw const RideCodeDirectoryException(
        'Enter a valid six-digit ride code.',
      );
    }
    return code;
  }

  Uri _joinCodeUri(String rideCode) {
    final base = configuration.baseUri!;
    final baseText = base.toString().endsWith('/')
        ? base.toString().substring(0, base.toString().length - 1)
        : base.toString();
    return Uri.parse(
      '$baseText/v1/join-codes/${Uri.encodeComponent(rideCode)}',
    );
  }

  @override
  void close() => _client.close();
}

class HttpInternetRelayClient
    implements InternetRelayApi, RelayCompatibilityApi {
  factory HttpInternetRelayClient({
    required InternetRelayConfiguration configuration,
    required http.Client client,
    RelayClientDescriptor? clientDescriptor,
    DateTime Function()? clock,
  }) => HttpInternetRelayClient._(
    configuration,
    client,
    clientDescriptor ?? RelayClientDescriptor.current(),
    clock ?? DateTime.now,
  );

  HttpInternetRelayClient._(
    this.configuration,
    this._client,
    this._clientDescriptor,
    this._clock,
  );

  @override
  final InternetRelayConfiguration configuration;
  final http.Client _client;
  final RelayClientDescriptor _clientDescriptor;
  final DateTime Function() _clock;
  RelayCompatibilityResult? _cachedCompatibility;

  @override
  Future<RelayCompatibilityResult> checkCompatibility() async {
    final result = await _fetchCompatibility(
      configuration: configuration,
      client: _client,
      descriptor: _clientDescriptor,
      clock: _clock,
      cached: _cachedCompatibility,
    );
    _cachedCompatibility = result;
    return result;
  }

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
        'authorization': 'Bearer ${_rideBearerToken(session)}',
        'content-type': 'application/json',
        'idempotency-key': _idempotencyKey(bodyBytes),
        'x-ride-relay-device': session.localRiderId,
        ..._clientDescriptor.headers,
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
    } on http.ClientException {
      throw const InternetRelayException(
        'Internet relay is temporarily unavailable. Check your connection and try again.',
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
      throw _failureForResponse(response, responseBytes);
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

  InternetRelayException _failureForResponse(
    http.StreamedResponse response,
    Uint8List responseBytes,
  ) {
    final status = response.statusCode;
    final unauthorized = status == 401 || status == 403;
    final retryable = status == 408 || status == 429 || status >= 500;
    String? code;
    String? serverMessage;
    Uri? actionUrl;
    try {
      final decoded = jsonDecode(utf8.decode(responseBytes));
      if (decoded is Map) {
        code = decoded['code'] as String?;
        serverMessage = decoded['message'] as String?;
        actionUrl = Uri.tryParse(decoded['updateUrl'] as String? ?? '');
      }
    } on Object {
      // A bounded but invalid error body falls back to the safe status text.
    }
    return InternetRelayException(
      serverMessage ??
          (unauthorized
              ? 'Internet relay rejected this ride credential.'
              : 'Internet relay returned HTTP $status.'),
      retryable: retryable,
      unauthorized: unauthorized,
      retryAfter: status == 429 ? _parseRetryAfter(response.headers) : null,
      statusCode: status,
      code: code,
      actionUrl: actionUrl,
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

Future<RelayCompatibilityResult> _fetchCompatibility({
  required InternetRelayConfiguration configuration,
  required http.Client client,
  required RelayClientDescriptor descriptor,
  required DateTime Function() clock,
  required RelayCompatibilityResult? cached,
}) async {
  final configurationError = configuration.configurationError;
  if (configurationError != null) {
    throw InternetRelayException(configurationError);
  }
  final now = clock();
  if (cached != null && now.isBefore(cached.validUntil)) return cached;
  final base = configuration.baseUri!;
  final baseText = base.toString().endsWith('/')
      ? base.toString().substring(0, base.toString().length - 1)
      : base.toString();
  final request = http.Request('GET', Uri.parse('$baseText/v1/compatibility'))
    ..followRedirects = false
    ..headers.addAll({'accept': 'application/json', ...descriptor.headers});
  try {
    final response = await client
        .send(request)
        .timeout(configuration.headerTimeout);
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      configuration.bodyTimeout,
    )) {
      if (bytes.length + chunk.length > 16 * 1024) {
        throw const InternetRelayException(
          'Compatibility response exceeded the size limit.',
        );
      }
      bytes.add(chunk);
    }
    if (response.statusCode == 404) {
      return RelayCompatibilityResult(
        disposition: RelayCompatibilityDisposition.legacyCompatible,
        serverProtocol: 1,
        minimumClientProtocol: 1,
        capabilities: const {},
        checkedAt: now,
        validUntil: now.add(const Duration(minutes: 5)),
        message: 'Legacy protocol-1 relay; newer ride features stay local.',
      );
    }
    final body = bytes.takeBytes();
    if (response.statusCode != 200) {
      String? message;
      String? code;
      Uri? updateUri;
      try {
        final value = jsonDecode(utf8.decode(body));
        if (value is Map) {
          message = value['message'] as String?;
          code = value['code'] as String?;
          updateUri = _safeUri(value['updateUrl']);
        }
      } on Object {
        // Fall through to the bounded status message.
      }
      throw InternetRelayException(
        message ?? 'Ride service compatibility check failed.',
        retryable: response.statusCode == 429 || response.statusCode >= 500,
        statusCode: response.statusCode,
        code: code,
        actionUrl: updateUri,
      );
    }
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map) {
      throw const FormatException('Compatibility response is not an object.');
    }
    final serverProtocol = decoded['serverProtocol'];
    final minimumClientProtocol = decoded['minimumClientProtocol'];
    final maximumClientProtocol = decoded['maximumClientProtocol'];
    final rawCapabilities = decoded['capabilities'];
    final rawRequired = decoded['requiredCapabilities'];
    final rawUpdateUrls = decoded['updateUrls'];
    final cacheSeconds = decoded['cacheSeconds'];
    if (serverProtocol is! int ||
        minimumClientProtocol is! int ||
        maximumClientProtocol is! int ||
        rawCapabilities is! List ||
        rawRequired is! List ||
        rawUpdateUrls is! Map ||
        cacheSeconds is! int) {
      throw const FormatException('Compatibility fields are invalid.');
    }
    final capabilities = rawCapabilities.cast<String>().toSet();
    final required = rawRequired.cast<String>().toSet();
    final missingRequired = required.difference(descriptor.capabilities);
    final updateUri = _safeUri(
      rawUpdateUrls[descriptor.platform] ?? rawUpdateUrls['default'],
    );
    final disposition =
        descriptor.protocolVersion < minimumClientProtocol ||
            missingRequired.isNotEmpty
        ? RelayCompatibilityDisposition.updateRequired
        : descriptor.protocolVersion > maximumClientProtocol
        ? RelayCompatibilityDisposition.serverUpgradeRequired
        : RelayCompatibilityDisposition.compatible;
    final message = switch (disposition) {
      RelayCompatibilityDisposition.updateRequired =>
        'Update Tail End Charlie before joining or synchronizing this ride.',
      RelayCompatibilityDisposition.serverUpgradeRequired =>
        'This app is newer than the configured ride service. Try again after the service is updated.',
      _ => null,
    };
    return RelayCompatibilityResult(
      disposition: disposition,
      serverProtocol: serverProtocol,
      minimumClientProtocol: minimumClientProtocol,
      capabilities: Set.unmodifiable(capabilities),
      checkedAt: now,
      validUntil: now.add(Duration(seconds: cacheSeconds.clamp(30, 3600))),
      message: message,
      updateUri: updateUri,
    );
  } on InternetRelayException {
    rethrow;
  } on TimeoutException {
    if (cached != null && now.isBefore(cached.validUntil)) return cached;
    throw const InternetRelayException(
      'Ride service compatibility check timed out.',
      retryable: true,
      code: 'temporarily_unavailable',
    );
  } on http.ClientException {
    if (cached != null && now.isBefore(cached.validUntil)) return cached;
    throw const InternetRelayException(
      'Ride service is temporarily unavailable. Check your connection and try again.',
      retryable: true,
      code: 'temporarily_unavailable',
    );
  } on Object catch (error) {
    throw InternetRelayException(
      'Invalid ride service compatibility response: $error',
    );
  }
}

Uri? _safeUri(Object? value) {
  if (value is! String) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'https' && uri.scheme != 'http') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri;
}

String _rideBearerToken(RideSession session) {
  final digest = Hmac(
    sha256,
    utf8.encode(session.inviteSecret),
  ).convert(utf8.encode('ride-relay-internet-token-v1\n${session.rideId}'));
  return 'rr1_${base64Url.encode(digest.bytes).replaceAll('=', '')}';
}

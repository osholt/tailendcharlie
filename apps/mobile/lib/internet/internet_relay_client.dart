import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../domain/ride_event.dart';
import '../domain/rider_location.dart';
import '../domain/ride_session.dart';
import '../relay/relay_event_compatibility.dart';

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
  static const preStartPresence = 'pre-start-presence-v1';

  /// Presence that spans the pre-start and started phases and reports a
  /// cursor-independent ride roster. Supersedes [preStartPresence]; both are
  /// advertised so an older relay keeps working.
  static const livePresence = 'live-presence-v2';
  static const routeRevisions = 'route-revisions-v1';
  static const pushNotifications = 'push-notifications-v1';
  static const observerAccess = 'observer-access-v1';
  static const trafficIncidents = 'traffic-incidents-v1';
  static const trafficReroutes = 'traffic-reroutes-v1';

  /// The leader asking a named rider to take the Tail End Charlie role, and
  /// that rider's answer (issue #128 part 1).
  static const tecRoleAssignment = 'tec-role-assignment-v1';

  /// A separated rider's advisory rejoin route, relayed to the ride leader only
  /// (issue #128 part 2).
  static const rejoinRouteSharing = 'rejoin-route-sharing-v1';

  /// A rider's own phone number, addressed to the ride's coordination roles
  /// (issue #188). Named so a client can say "the ride service cannot carry
  /// this" instead of appearing to have shared a number that went nowhere.
  static const riderContactSharing = 'rider-contact-sharing-v1';

  /// Anonymous rider verdicts on catalogued roads (issue #159).
  ///
  /// Not an event type, so it is not in the worker's event-to-capability map: it
  /// is a standalone unauthenticated endpoint. It is negotiated through the same
  /// compatibility document so a relay that does not accept ratings produces a
  /// named limitation and the answers stay durable on the phone, instead of the
  /// rider being thanked for something that went nowhere.
  static const roadRatings = 'road-ratings-v1';

  /// The leader un-ending a ride that ended by mistake (#206, #207).
  ///
  /// Named so a client can refuse to offer the action rather than record a
  /// reopen that never leaves the phone: a leader back on the map while every
  /// other rider still sees a finished ride is worse than being told it cannot
  /// be done.
  static const rideReopen = 'ride-reopen-v1';

  static const current = {
    rideStart,
    membership,
    preStartPresence,
    livePresence,
    routeRevisions,
    pushNotifications,
    observerAccess,
    trafficIncidents,
    trafficReroutes,
    tecRoleAssignment,
    rejoinRouteSharing,
    riderContactSharing,
    roadRatings,
    rideReopen,
  };
}

class RelayClientDescriptor {
  const RelayClientDescriptor({
    required this.protocolVersion,
    required this.platform,
    required this.appVersion,
    required this.appBuild,
    required this.capabilities,
    this.distributionTrack = unknownVersion,
  });

  /// The build's real identity.
  ///
  /// When a build channel does not inject `RIDE_RELAY_APP_VERSION` /
  /// `RIDE_RELAY_APP_BUILD` the descriptor reports [unknownVersion] instead of
  /// a plausible-looking constant. A wrong version is worse than an absent one:
  /// it makes every version-conditional diagnostic silently misleading.
  factory RelayClientDescriptor.current() => RelayClientDescriptor(
    protocolVersion: 1,
    platform: defaultTargetPlatform.name,
    appVersion: _declaredAppVersion,
    appBuild: _declaredAppBuild,
    capabilities: RelayProtocolCapabilities.current,
    distributionTrack: _declaredDistributionTrack,
  );

  static const unknownVersion = 'unknown';

  static const _rawAppVersion = String.fromEnvironment(
    'RIDE_RELAY_APP_VERSION',
  );
  static const _rawAppBuild = String.fromEnvironment('RIDE_RELAY_APP_BUILD');
  static const _rawDistributionTrack = String.fromEnvironment(
    'RIDE_RELAY_DISTRIBUTION_TRACK',
  );

  static String get _declaredAppVersion =>
      _sanitiseDescriptorValue(_rawAppVersion);

  static String get _declaredAppBuild => _sanitiseDescriptorValue(_rawAppBuild);

  static String get _declaredDistributionTrack =>
      _sanitiseDescriptorValue(_rawDistributionTrack);

  /// Keeps a dart-define out of the header set unless it is a plain, bounded
  /// token, so a malformed injection can never smuggle header syntax.
  static String _sanitiseDescriptorValue(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed.length > 40) return unknownVersion;
    if (!RegExp(r'^[A-Za-z0-9._+-]+$').hasMatch(trimmed)) return unknownVersion;
    return trimmed;
  }

  final int protocolVersion;
  final String platform;
  final String appVersion;
  final String appBuild;
  final Set<String> capabilities;

  /// The distribution track the build was destined for, as stamped in by the
  /// release workflow, or [unknownVersion] on an unstamped build.
  ///
  /// Sent to the relay so the reverse proxy's access log answers "which track
  /// is this tester on" without asking the tester, which is exactly the
  /// question the #101 delivery investigation could not answer. Parsed into
  /// [DistributionTrack] by `BuildIdentity.fromEnvironment`, so the About
  /// screen and this header can never disagree.
  final String distributionTrack;

  /// False when the build channel did not inject its version, so callers can
  /// say "this build does not report its version" instead of quoting a wrong
  /// one.
  bool get reportsAppVersion =>
      appVersion != unknownVersion && appBuild != unknownVersion;

  Map<String, String> get headers => {
    'x-tailendcharlie-protocol': '$protocolVersion',
    'x-tailendcharlie-platform': platform,
    'x-tailendcharlie-app-version': appVersion,
    'x-tailendcharlie-app-build': appBuild,
    'x-tailendcharlie-distribution-track': distributionTrack,
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
    this.ignoredEventCount = 0,
    this.ignoredEventTypes = const {},
  });

  final String cursor;
  final Set<String> acceptedEventIds;
  final List<RideEvent> events;

  /// Events in the batch this build does not understand. They are skipped, the
  /// cursor still advances past them, and the rest of the batch is delivered:
  /// one future event type must never stall the whole ride.
  final int ignoredEventCount;

  /// The sanitised type names that were skipped, for a named diagnostic. Only
  /// short, alphanumeric names survive sanitisation.
  final Set<String> ignoredEventTypes;
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

abstract interface class PreStartPresenceApi {
  InternetRelayConfiguration get configuration;

  Future<PreStartPresenceResult> synchronizePreStartPresence({
    required RideSession session,
    required RiderLocation? position,
    required bool clear,
  });

  void close();
}

/// The ride phase the presence channel reports, so the client never has to
/// infer continuity from its own journal cursor.
enum RidePresencePhase { open, started, ended, unknown }

/// One rider the presence channel says is in the ride.
///
/// Derived by the relay from durable membership events without consulting the
/// caller's cursor, so a wedged or backed-off batch sync cannot hide a
/// participant.
class PresenceRosterEntry {
  const PresenceRosterEntry({
    required this.riderId,
    required this.displayName,
    required this.role,
    required this.joinedAt,
    this.left = false,
    this.leftAt,
  });

  final String riderId;
  final String displayName;
  final String role;
  final DateTime joinedAt;
  final bool left;

  /// When the relay recorded the departure. Absent from an older relay, which
  /// reports [left] alone.
  final DateTime? leftAt;
}

class PreStartPresenceResult {
  const PreStartPresenceResult({
    required this.locations,
    required this.ttl,
    this.phase = RidePresencePhase.unknown,
    this.roster = const [],
    this.legacyPeerRiderIds = const {},
    this.livePresenceServed = false,
    this.serverTime,
    this.unreadablePositionCount = 0,
  });

  final List<RiderLocation> locations;
  final Duration ttl;

  /// The relay's own clock at the moment it built this reply, when it reports
  /// one. It is the only clock two phones share, so it is what a peer's
  /// relay-stamped position is aged against.
  final DateTime? serverTime;

  /// Positions in the reply this build could not decode. They are skipped
  /// individually: one unreadable position must never discard the whole reply,
  /// which is how a single bad row used to hide every rider at once.
  final int unreadablePositionCount;

  /// The phase the relay reports for this ride.
  final RidePresencePhase phase;

  /// Riders the relay knows about, independent of the event batch.
  final List<PresenceRosterEntry> roster;

  /// Riders whose presence was published by a build without live-presence
  /// support, so their position will stop once the ride starts.
  final Set<String> legacyPeerRiderIds;

  /// True when the relay served positions under the live-presence contract
  /// rather than the legacy pre-start-only one.
  final bool livePresenceServed;
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

  /// How hard to try the compatibility probe before giving up on an answer and
  /// letting the directory call itself speak (#208).
  static const _compatibilityProbeAttempts = 2;
  static const _compatibilityRetryBackoff = Duration(milliseconds: 300);

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
    } on Object {
      // Deliberately not interpolated: a transport or TLS error message can
      // carry the relay hostname and port.
      throw const RideCodeDirectoryException(
        'Ride code service returned an invalid response.',
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

  /// Checks compatibility before a directory call, and refuses the call only on
  /// a definite answer that the two ends disagree.
  ///
  /// A probe that times out says nothing about compatibility, and it used to be
  /// fatal: a tester on a working 4G connection could not rejoin her own ride,
  /// and the sentence she was shown was "Ride service compatibility check timed
  /// out" (#208). Treating silence as incompatible is the wrong default for an
  /// offline-first app — and it is not even the safe one, because
  /// `InternetRelayWorker`'s `updateRequired` phase is what actually stops an
  /// incompatible client from synchronising. That gate stays where it is.
  ///
  /// So: retry a little, then proceed on anything short of a verdict. A join that
  /// goes ahead against an unreachable relay fails at the directory call itself,
  /// with an error about the connection, which is the truth.
  Future<void> _ensureCompatibility() async {
    for (var attempt = 0; ; attempt += 1) {
      try {
        final result = await _fetchCompatibility(
          configuration: configuration,
          client: _client,
          descriptor: _clientDescriptor,
          clock: _clock,
          cached: _cachedCompatibility,
        );
        _cachedCompatibility = result;
        if (result.canSynchronize ||
            result.disposition ==
                RelayCompatibilityDisposition.temporarilyUnavailable) {
          return;
        }
        // A real disagreement about the protocol. Updating the app is the only
        // way through it, so saying so now beats a confusing failure later.
        throw RideCodeDirectoryException(
          result.message ?? 'This app and the ride service are not compatible.',
        );
      } on InternetRelayException {
        if (attempt >= _compatibilityProbeAttempts - 1) return;
        await Future<void>.delayed(_compatibilityRetryBackoff * (attempt + 1));
      }
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
      final remoteEvents = <RideEvent>[];
      final ignoredTypes = <String>{};
      var ignoredCount = 0;
      for (final value in eventValues) {
        if (value is! Map) {
          throw const FormatException('Invalid event object.');
        }
        final raw = Map<String, Object?>.from(value);
        if (utf8.encode(jsonEncode(raw)).length >
            configuration.maximumEventBytes) {
          throw const FormatException('Response event exceeds the size limit.');
        }
        // A newer peer's event type, schema version or added field must be
        // skipped, not treated as a corrupt batch. Failing the whole response
        // would stall the cursor forever and hide every rider.
        final unsupported = describeUnsupportedRelayEvent(raw);
        if (unsupported != null) {
          ignoredCount += 1;
          ignoredTypes.add(unsupported);
          continue;
        }
        final event = RideEvent.fromJson(raw);
        _validateEventForRide(event, session.rideId);
        remoteEvents.add(event);
      }
      return InternetSyncResult(
        cursor: responseCursor,
        acceptedEventIds: acceptedIds,
        events: List.unmodifiable(remoteEvents),
        ignoredEventCount: ignoredCount,
        ignoredEventTypes: Set.unmodifiable(ignoredTypes),
      );
    } on InternetRelayException {
      rethrow;
    } on Object {
      throw const InternetRelayException(
        'Internet relay returned a response this app could not read.',
      );
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
    var retryable = status == 408 || status == 429 || status >= 500;
    String? code;
    String? serverMessage;
    Uri? actionUrl;
    try {
      final decoded = jsonDecode(utf8.decode(responseBytes));
      if (decoded is Map) {
        code = decoded['code'] as String?;
        serverMessage =
            decoded['message'] as String? ?? decoded['error'] as String?;
        actionUrl = Uri.tryParse(decoded['updateUrl'] as String? ?? '');
        if (status == 400 && serverMessage == 'Invalid cursor') {
          code = 'invalid_cursor';
          retryable = true;
        }
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

class HttpPreStartPresenceClient implements PreStartPresenceApi {
  factory HttpPreStartPresenceClient({
    required InternetRelayConfiguration configuration,
    required http.Client client,
    RelayClientDescriptor? clientDescriptor,
    DateTime Function()? clock,
  }) => HttpPreStartPresenceClient._(
    configuration,
    client,
    clientDescriptor ?? RelayClientDescriptor.current(),
    clock ?? DateTime.now,
  );

  HttpPreStartPresenceClient._(
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
  Future<PreStartPresenceResult> synchronizePreStartPresence({
    required RideSession session,
    required RiderLocation? position,
    required bool clear,
  }) async {
    final compatibility = await _fetchCompatibility(
      configuration: configuration,
      client: _client,
      descriptor: _clientDescriptor,
      clock: _clock,
      cached: _cachedCompatibility,
    );
    _cachedCompatibility = compatibility;
    final servesLivePresence = compatibility.supports(
      RelayProtocolCapabilities.livePresence,
    );
    if (!servesLivePresence &&
        !compatibility.supports(RelayProtocolCapabilities.preStartPresence)) {
      throw const InternetRelayException(
        'This ride service does not support live rider positions yet.',
        code: 'feature_unsupported',
      );
    }
    if (clear && position != null) {
      throw const InternetRelayException(
        'A pre-start position cannot be published and cleared together.',
      );
    }
    if (session.rideId.isEmpty ||
        session.rideId.length > 128 ||
        session.localRiderId.isEmpty ||
        session.localRiderId.length > 128 ||
        session.inviteSecret.length < 16) {
      throw const InternetRelayException(
        'Ride identity is invalid for pre-start positions.',
      );
    }
    if (position != null && position.riderId != session.localRiderId) {
      throw const InternetRelayException(
        'A rider can only publish their own pre-start position.',
      );
    }
    final bodyBytes = utf8.encode(
      jsonEncode({
        'protocolVersion': 1,
        'deviceId': session.localRiderId,
        'position': position == null
            ? null
            : {
                'displayName': position.displayName,
                'role': position.role.name,
                'motorcycleStyle': position.motorcycleStyle.name,
                'riderColor': position.riderColor.name,
                'sample': position.sample.toJson(),
              },
        'clear': clear,
      }),
    );
    if (bodyBytes.length > configuration.maximumRequestBytes) {
      throw const InternetRelayException(
        'Pre-start position request exceeds the size limit.',
      );
    }
    final request = http.Request('POST', _presenceUri(session.rideId))
      ..followRedirects = false
      ..headers.addAll({
        'accept': 'application/json',
        'authorization': 'Bearer ${_rideBearerToken(session)}',
        'content-type': 'application/json',
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
        'Pre-start position service timed out.',
        retryable: true,
      );
    } on http.ClientException {
      throw const InternetRelayException(
        'Pre-start positions are temporarily unavailable.',
        retryable: true,
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      configuration.bodyTimeout,
    )) {
      if (bytes.length + chunk.length > configuration.maximumResponseBytes) {
        throw const InternetRelayException(
          'Pre-start position response exceeds the size limit.',
        );
      }
      bytes.add(chunk);
    }
    final responseBytes = bytes.takeBytes();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String? message;
      try {
        final value = jsonDecode(utf8.decode(responseBytes));
        if (value is Map) {
          message = (value['error'] ?? value['message']) as String?;
        }
      } on Object {
        // Use the bounded fallback below.
      }
      throw InternetRelayException(
        message ?? 'Pre-start position service rejected the request.',
        retryable:
            response.statusCode == 404 ||
            response.statusCode == 429 ||
            response.statusCode >= 500,
        unauthorized: response.statusCode == 401 || response.statusCode == 403,
        statusCode: response.statusCode,
      );
    }
    try {
      final decoded = jsonDecode(utf8.decode(responseBytes));
      if (decoded is! Map ||
          decoded['protocolVersion'] != 1 ||
          decoded['ttlSeconds'] is! int ||
          decoded['positions'] is! List) {
        throw const FormatException('Invalid presence response envelope.');
      }
      final ttlSeconds = (decoded['ttlSeconds'] as int).clamp(15, 300);
      final values = decoded['positions'] as List;
      if (values.length > 1000) {
        throw const FormatException('Too many live positions.');
      }
      final serverTime = DateTime.tryParse(
        decoded['serverTime'] as String? ?? '',
      )?.toLocal();
      final locations = <RiderLocation>[];
      final legacyPeers = <String>{};
      var unreadable = 0;
      for (final value in values) {
        // One unusable position is skipped, never fatal. Discarding the whole
        // reply took every other rider's position and the roster with it, and a
        // device whose clock ran ahead of the relay hit that on every single
        // poll: the relay had already deleted every expired row on its own
        // clock, so the local re-check could only ever be measuring skew.
        if (value is! Map) {
          unreadable += 1;
          continue;
        }
        final raw = Map<String, Object?>.from(value);
        try {
          final expiresAt = DateTime.parse(raw['expiresAt']! as String);
          final receivedAt = DateTime.parse(raw['receivedAt']! as String);
          // Judged on the relay's own clock when it reports one, and otherwise
          // not judged at all: only the relay can say what it has expired.
          if (!expiresAt.isAfter(serverTime ?? receivedAt)) {
            unreadable += 1;
            continue;
          }
          // Unknown response fields from a newer relay are ignored rather than
          // rejected, so only the fields this build knows are decoded.
          final location = RiderLocation.fromJson({
            for (final field in _presenceLocationFields)
              if (raw.containsKey(field)) field: raw[field],
          });
          if (raw['livePresence'] == false) legacyPeers.add(location.riderId);
          locations.add(location);
        } on Object {
          unreadable += 1;
        }
      }
      return PreStartPresenceResult(
        locations: List.unmodifiable(locations),
        ttl: Duration(seconds: ttlSeconds),
        phase: _presencePhase(decoded['phase']),
        roster: _presenceRoster(decoded['members']),
        legacyPeerRiderIds: Set.unmodifiable(legacyPeers),
        livePresenceServed: servesLivePresence,
        serverTime: serverTime,
        unreadablePositionCount: unreadable,
      );
    } on InternetRelayException {
      rethrow;
    } on Object {
      throw const InternetRelayException(
        'The live position service returned a response this app could not read.',
      );
    }
  }

  static const _presenceLocationFields = {
    'riderId',
    'displayName',
    'role',
    'sample',
    'receivedAt',
    'motorcycleStyle',
    'riderColor',
  };

  /// An absent or unrecognised phase degrades to
  /// [RidePresencePhase.unknown] rather than failing: an older relay does not
  /// report one, and a newer relay may add one this build has never seen.
  static RidePresencePhase _presencePhase(Object? value) => switch (value) {
    'open' => RidePresencePhase.open,
    'started' => RidePresencePhase.started,
    'ended' => RidePresencePhase.ended,
    _ => RidePresencePhase.unknown,
  };

  static List<PresenceRosterEntry> _presenceRoster(Object? value) {
    if (value is! List) return const [];
    final entries = <PresenceRosterEntry>[];
    for (final item in value.take(1000)) {
      if (item is! Map) continue;
      final riderId = item['riderId'];
      final displayName = item['displayName'];
      final role = item['role'];
      final joinedAt = DateTime.tryParse(item['joinedAt'] as String? ?? '');
      if (riderId is! String ||
          riderId.isEmpty ||
          riderId.length > 128 ||
          displayName is! String ||
          displayName.isEmpty ||
          displayName.length > 80 ||
          role is! String ||
          joinedAt == null) {
        continue;
      }
      entries.add(
        PresenceRosterEntry(
          riderId: riderId,
          displayName: displayName,
          role: role,
          joinedAt: joinedAt.toLocal(),
          left: item['left'] == true,
          leftAt: DateTime.tryParse(item['leftAt'] as String? ?? '')?.toLocal(),
        ),
      );
    }
    return List.unmodifiable(entries);
  }

  Uri _presenceUri(String rideId) {
    final base = configuration.baseUri!;
    final baseText = base.toString().endsWith('/')
        ? base.toString().substring(0, base.toString().length - 1)
        : base.toString();
    return Uri.parse(
      '$baseText/v1/rides/${Uri.encodeComponent(rideId)}/presence:sync',
    );
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
  } on FormatException {
    throw const InternetRelayException(
      'The ride service compatibility response could not be read.',
    );
  } on Object {
    // A transport or TLS failure message can name the relay host and port, so
    // it is never surfaced. Treated as retryable because it is a connection
    // class of failure, not a protocol disagreement.
    if (cached != null && now.isBefore(cached.validUntil)) return cached;
    throw const InternetRelayException(
      'Ride service is temporarily unavailable. Check your connection and try again.',
      retryable: true,
      code: 'temporarily_unavailable',
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

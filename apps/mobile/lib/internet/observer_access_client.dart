import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../domain/ride_session.dart';
import 'internet_relay_client.dart';

class ObserverAccessConfiguration {
  const ObserverAccessConfiguration({
    required this.relay,
    required this.webBaseUri,
  });

  factory ObserverAccessConfiguration.fromEnvironment() {
    const webValue = String.fromEnvironment(
      'OBSERVER_WEB_BASE_URL',
      defaultValue: 'https://relay.tailendcharlie.app/observer.html',
    );
    return ObserverAccessConfiguration(
      relay: InternetRelayConfiguration.fromEnvironment(),
      webBaseUri: Uri.tryParse(webValue.trim()),
    );
  }

  final InternetRelayConfiguration relay;
  final Uri? webBaseUri;

  String? get configurationError {
    final relayError = relay.configurationError;
    if (relayError != null) return relayError;
    final web = webBaseUri;
    if (web == null ||
        web.scheme != 'https' ||
        web.host.isEmpty ||
        web.userInfo.isNotEmpty ||
        web.hasQuery ||
        web.hasFragment) {
      return 'Observer links require an absolute HTTPS web address.';
    }
    final relayUri = relay.baseUri;
    if (relayUri == null || relayUri.origin != web.origin) {
      return 'Observer links must use the same service host as the ride relay.';
    }
    return null;
  }
}

class ObserverGrant {
  const ObserverGrant({
    required this.id,
    required this.label,
    required this.createdAt,
    required this.expiresAt,
    this.revokedAt,
  });

  final String id;
  final String label;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? revokedAt;

  bool isActiveAt(DateTime now) => revokedAt == null && expiresAt.isAfter(now);

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'revokedAt': revokedAt?.toUtc().toIso8601String(),
  };

  factory ObserverGrant.fromJson(Map<String, Object?> json) => ObserverGrant(
    id: json['id']! as String,
    label: json['label']! as String,
    createdAt: DateTime.parse(json['createdAt']! as String).toLocal(),
    expiresAt: DateTime.parse(json['expiresAt']! as String).toLocal(),
    revokedAt: switch (json['revokedAt']) {
      final String value => DateTime.parse(value).toLocal(),
      _ => null,
    },
  );
}

class ObserverGrantCredentials {
  const ObserverGrantCredentials({
    required this.grant,
    required this.managementToken,
    required this.publisherToken,
    required this.observerToken,
  });

  final ObserverGrant grant;
  final String managementToken;
  final String publisherToken;
  final String observerToken;

  Map<String, Object?> toJson() => {
    'grant': grant.toJson(),
    'managementToken': managementToken,
    'publisherToken': publisherToken,
    'observerToken': observerToken,
  };

  factory ObserverGrantCredentials.fromJson(Map<String, Object?> json) {
    final grant = json['grant'];
    if (grant is! Map) {
      throw const FormatException('Observer grant is invalid.');
    }
    final result = ObserverGrantCredentials(
      grant: ObserverGrant.fromJson(Map<String, Object?>.from(grant)),
      managementToken: json['managementToken']! as String,
      publisherToken: json['publisherToken']! as String,
      observerToken: json['observerToken']! as String,
    );
    if (!RegExp(r'^om1_[A-Za-z0-9_-]{43}$').hasMatch(result.managementToken) ||
        !RegExp(r'^op1_[A-Za-z0-9_-]{43}$').hasMatch(result.publisherToken) ||
        !RegExp(r'^ro1_[A-Za-z0-9_-]{43}$').hasMatch(result.observerToken)) {
      throw const FormatException('Observer credentials are invalid.');
    }
    return result;
  }
}

class ObserverInvite {
  const ObserverInvite({required this.credentials, required this.shareUri});

  final ObserverGrantCredentials credentials;
  final Uri shareUri;

  ObserverGrant get grant => credentials.grant;
}

class ObserverPublishedPosition {
  const ObserverPublishedPosition({
    required this.latitude,
    required this.longitude,
    required this.accuracyMeters,
    required this.recordedAt,
  });

  final double latitude;
  final double longitude;
  final double accuracyMeters;
  final DateTime recordedAt;

  Map<String, Object?> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    'accuracyMeters': accuracyMeters,
    'recordedAt': recordedAt.toUtc().toIso8601String(),
  };
}

class ObserverPublishedAssistance {
  const ObserverPublishedAssistance({
    required this.kind,
    required this.reportedAt,
  });

  final String kind;
  final DateTime reportedAt;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'reportedAt': reportedAt.toUtc().toIso8601String(),
  };
}

class ObserverLocalAssistanceState {
  const ObserverLocalAssistanceState({
    required this.updatedAt,
    this.assistance,
  });

  final DateTime updatedAt;
  final ObserverPublishedAssistance? assistance;

  Map<String, Object?> toJson() => {
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'assistance': assistance?.toJson(),
  };

  factory ObserverLocalAssistanceState.fromJson(Map<String, Object?> json) {
    final rawAssistance = json['assistance'];
    ObserverPublishedAssistance? assistance;
    if (rawAssistance != null) {
      final value = Map<String, Object?>.from(rawAssistance as Map);
      final kind = value['kind'];
      if (kind != 'assistance' && kind != 'emergencyStop') {
        throw const FormatException('Observer assistance is invalid.');
      }
      assistance = ObserverPublishedAssistance(
        kind: kind! as String,
        reportedAt: DateTime.parse(value['reportedAt']! as String),
      );
    }
    return ObserverLocalAssistanceState(
      updatedAt: DateTime.parse(json['updatedAt']! as String),
      assistance: assistance,
    );
  }
}

class ObserverPublishedSnapshot {
  const ObserverPublishedSnapshot({
    required this.subjectName,
    required this.snapshotGeneratedAt,
    required this.rideStatus,
    required this.statusUpdatedAt,
    required this.assistanceUpdatedAt,
    this.position,
    this.assistance,
  });

  final String subjectName;
  final DateTime snapshotGeneratedAt;
  final String rideStatus;
  final DateTime statusUpdatedAt;
  final DateTime assistanceUpdatedAt;
  final ObserverPublishedPosition? position;
  final ObserverPublishedAssistance? assistance;

  Map<String, Object?> toJson() => {
    'subjectName': subjectName,
    'snapshotGeneratedAt': snapshotGeneratedAt.toUtc().toIso8601String(),
    'rideStatus': rideStatus,
    'statusUpdatedAt': statusUpdatedAt.toUtc().toIso8601String(),
    'assistanceUpdatedAt': assistanceUpdatedAt.toUtc().toIso8601String(),
    'position': position?.toJson(),
    'assistance': assistance?.toJson(),
  };
}

abstract interface class ObserverAccessApi {
  ObserverAccessConfiguration get configuration;

  Future<ObserverGrantCredentials> create(
    RideSession session, {
    required String label,
    required Duration duration,
  });

  Future<ObserverGrant> inspect(ObserverGrantCredentials credentials);

  Future<void> publish(
    ObserverGrantCredentials credentials,
    ObserverPublishedSnapshot snapshot,
  );

  Future<void> revoke(ObserverGrantCredentials credentials);

  Uri shareUri(ObserverGrantCredentials credentials);

  void close();
}

class HttpObserverAccessClient implements ObserverAccessApi {
  factory HttpObserverAccessClient({
    required ObserverAccessConfiguration configuration,
    required http.Client client,
  }) => HttpObserverAccessClient._(configuration, client);

  HttpObserverAccessClient._(this.configuration, this._client);

  @override
  final ObserverAccessConfiguration configuration;
  final http.Client _client;

  @override
  Future<ObserverGrantCredentials> create(
    RideSession session, {
    required String label,
    required Duration duration,
  }) async {
    final minutes = duration.inMinutes;
    if (label.trim().isEmpty || label.trim().length > 80) {
      throw const InternetRelayException(
        'Enter a label of no more than 80 characters.',
      );
    }
    if (minutes < 30 || minutes > 24 * 60) {
      throw const InternetRelayException(
        'Observer access must last between 30 minutes and 24 hours.',
      );
    }
    final request = http.Request('POST', _rideGrantsUri(session.rideId))
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode({
        'label': label.trim(),
        'durationMinutes': minutes,
        'consentConfirmed': true,
      });
    final response = await _send(request, bearer: _rideBearer(session));
    final decoded = _jsonObject(response);
    try {
      final credentials = ObserverGrantCredentials(
        grant: ObserverGrant.fromJson(decoded),
        managementToken: decoded['managementToken']! as String,
        publisherToken: decoded['publisherToken']! as String,
        observerToken: decoded['observerToken']! as String,
      );
      return ObserverGrantCredentials.fromJson(credentials.toJson());
    } on Object {
      throw const InternetRelayException(
        'Observer access returned invalid credentials.',
      );
    }
  }

  @override
  Future<ObserverGrant> inspect(ObserverGrantCredentials credentials) async {
    final response = await _send(
      http.Request('GET', _managementUri(credentials.grant.id)),
      bearer: credentials.managementToken,
    );
    try {
      return ObserverGrant.fromJson(_jsonObject(response));
    } on Object {
      throw const InternetRelayException(
        'Observer access returned an invalid grant.',
      );
    }
  }

  @override
  Future<void> publish(
    ObserverGrantCredentials credentials,
    ObserverPublishedSnapshot snapshot,
  ) async {
    final request = http.Request('PUT', _snapshotUri(credentials.grant.id))
      ..headers['content-type'] = 'application/json'
      ..body = jsonEncode(snapshot.toJson());
    await _send(request, bearer: credentials.publisherToken, expectBody: false);
  }

  @override
  Future<void> revoke(ObserverGrantCredentials credentials) async {
    await _send(
      http.Request('DELETE', _managementUri(credentials.grant.id)),
      bearer: credentials.managementToken,
      expectBody: false,
    );
  }

  @override
  Uri shareUri(ObserverGrantCredentials credentials) =>
      configuration.webBaseUri!.replace(
        fragment: '${credentials.grant.id}.${credentials.observerToken}',
      );

  Future<http.Response> _send(
    http.Request request, {
    required String bearer,
    bool expectBody = true,
  }) async {
    final error = configuration.configurationError;
    if (error != null) throw InternetRelayException(error);
    request
      ..followRedirects = false
      ..headers.addAll({
        'accept': 'application/json',
        'authorization': 'Bearer $bearer',
      });
    late http.StreamedResponse streamed;
    try {
      streamed = await _client
          .send(request)
          .timeout(configuration.relay.headerTimeout);
    } on TimeoutException {
      throw const InternetRelayException(
        'Observer access timed out.',
        retryable: true,
      );
    } on http.ClientException {
      throw const InternetRelayException(
        'Observer access is temporarily unavailable.',
        retryable: true,
      );
    }
    final bytes = await streamed.stream
        .fold<List<int>>(<int>[], (all, part) {
          if (all.length + part.length >
              configuration.relay.maximumResponseBytes) {
            throw const InternetRelayException(
              'Observer access response exceeds the size limit.',
            );
          }
          return all..addAll(part);
        })
        .timeout(configuration.relay.bodyTimeout);
    final response = http.Response.bytes(
      bytes,
      streamed.statusCode,
      headers: streamed.headers,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String? message;
      try {
        final value = jsonDecode(response.body);
        if (value is Map) {
          message = (value['error'] ?? value['message']) as String?;
        }
      } on Object {
        // Fall back to a bounded status-only message.
      }
      throw InternetRelayException(
        message ?? 'Observer access returned HTTP ${response.statusCode}.',
        retryable: response.statusCode == 429 || response.statusCode >= 500,
        retryAfter: switch (int.tryParse(
          response.headers['retry-after'] ?? '',
        )) {
          final int seconds when seconds > 0 => Duration(seconds: seconds),
          _ => null,
        },
        unauthorized: response.statusCode == 401 || response.statusCode == 403,
        statusCode: response.statusCode,
      );
    }
    if (expectBody &&
        !(response.headers['content-type'] ?? '').contains(
          'application/json',
        )) {
      throw const InternetRelayException(
        'Observer access returned a non-JSON response.',
      );
    }
    return response;
  }

  Map<String, Object?> _jsonObject(http.Response response) {
    try {
      final value = jsonDecode(response.body);
      if (value is! Map) throw const FormatException();
      return Map<String, Object?>.from(value);
    } on Object {
      throw const InternetRelayException(
        'Observer access returned an invalid response.',
      );
    }
  }

  Uri _rideGrantsUri(String rideId) {
    final prefix = _apiPrefix;
    return Uri.parse(
      '$prefix/v1/rides/${Uri.encodeComponent(rideId)}/observer-grants',
    );
  }

  Uri _managementUri(String grantId) => Uri.parse(
    '$_apiPrefix/v1/observer-grants/${Uri.encodeComponent(grantId)}/management',
  );

  Uri _snapshotUri(String grantId) => Uri.parse(
    '$_apiPrefix/v1/observer-grants/${Uri.encodeComponent(grantId)}/snapshot',
  );

  String get _apiPrefix =>
      configuration.relay.baseUri!.toString().replaceFirst(RegExp(r'/$'), '');

  String _rideBearer(RideSession session) {
    if (session.inviteSecret.length < 16) {
      throw const InternetRelayException(
        'Observer access requires an authenticated ride.',
      );
    }
    final digest = Hmac(
      sha256,
      utf8.encode(session.inviteSecret),
    ).convert(utf8.encode('ride-relay-internet-token-v1\n${session.rideId}'));
    return 'rr1_${base64Url.encode(digest.bytes).replaceAll('=', '')}';
  }

  @override
  void close() => _client.close();
}

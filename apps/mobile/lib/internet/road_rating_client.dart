import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../services/road_rating.dart';
import 'internet_relay_client.dart';

/// Where anonymous road ratings are sent.
///
/// The same origin as the rest of the discovery catalogue API, not the ride
/// relay's ride-scoped base URL. That is a deliberate structural separation: a
/// rating is submitted through a client that never holds a ride session, so
/// there is no derived ride bearer, device header or ride ID in scope to leak
/// into the request by accident (#159).
class RoadRatingConfiguration {
  const RoadRatingConfiguration(this.apiOrigin);

  factory RoadRatingConfiguration.fromEnvironment() {
    const value = String.fromEnvironment('RIDE_RELAY_DISCOVERY_API_URL');
    return RoadRatingConfiguration(
      value.trim().isEmpty ? null : Uri.tryParse(value.trim()),
    );
  }

  final Uri? apiOrigin;

  bool get isConfigured => configurationError == null;

  String? get configurationError {
    final origin = apiOrigin;
    if (origin == null) return 'No discovery catalogue endpoint is configured.';
    if (origin.scheme != 'https' || origin.host.isEmpty) {
      return 'Road ratings require an absolute HTTPS endpoint.';
    }
    if (origin.hasQuery || origin.hasFragment || origin.userInfo.isNotEmpty) {
      return 'Road rating endpoint cannot contain credentials, a query, or a '
          'fragment.';
    }
    return null;
  }

  Uri get submissionUri => apiOrigin!.resolve('/api/v1/discovery/road-ratings');

  /// The relay configuration used only to read the compatibility document, so
  /// the client can name the limitation when a relay does not accept ratings.
  /// That probe carries no rating.
  InternetRelayConfiguration get compatibilityConfiguration =>
      InternetRelayConfiguration(baseUri: apiOrigin?.resolve('/api'));
}

abstract interface class RoadRatingApi {
  Future<void> submit(RoadRating rating);

  void close();
}

class HttpRoadRatingClient implements RoadRatingApi {
  factory HttpRoadRatingClient({
    required RoadRatingConfiguration configuration,
    required http.Client client,
    Duration timeout = const Duration(seconds: 10),
  }) => HttpRoadRatingClient._(configuration, client, timeout);

  HttpRoadRatingClient._(this.configuration, this._client, this.timeout);

  final RoadRatingConfiguration configuration;
  final Duration timeout;
  final http.Client _client;

  @override
  Future<void> submit(RoadRating rating) async {
    final error = configuration.configurationError;
    if (error != null) throw InternetRelayException(error);
    final request = http.Request('POST', configuration.submissionUri)
      ..followRedirects = false
      // Nothing else. No authorization, no device header, and none of the
      // `x-tailendcharlie-*` descriptor headers: platform, app version, build
      // and distribution track together fingerprint a rider far better than a
      // rider ID would, and the relay does not need any of them to count a
      // verdict.
      ..headers.addAll(const {
        'accept': 'application/json',
        'content-type': 'application/json',
      })
      ..bodyBytes = utf8.encode(jsonEncode(rating.toRequestJson()));

    late http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(timeout);
    } on TimeoutException {
      throw const InternetRelayException(
        'Road rating submission timed out.',
        retryable: true,
      );
    } on http.ClientException {
      throw const InternetRelayException(
        'Road ratings are temporarily unavailable.',
        retryable: true,
      );
    }
    // Drain a bounded amount so the connection can be reused; the relay answers
    // 204 with no body, and anything it does send is not needed.
    var drained = 0;
    await for (final chunk in response.stream.timeout(timeout)) {
      drained += chunk.length;
      if (drained > 4096) break;
    }
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw InternetRelayException(
      'Road rating was not accepted (HTTP ${response.statusCode}).',
      retryable: response.statusCode == 429 || response.statusCode >= 500,
      statusCode: response.statusCode,
      retryAfter: _retryAfter(response.headers['retry-after']),
    );
  }

  static Duration? _retryAfter(String? value) {
    final seconds = int.tryParse(value?.trim() ?? '');
    if (seconds == null || seconds <= 0) return null;
    return Duration(seconds: seconds.clamp(1, 3600));
  }

  @override
  void close() => _client.close();
}

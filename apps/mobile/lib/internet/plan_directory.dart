import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'internet_relay_client.dart';

/// A fetched pre-ride route plan. Unrelated to a live ride: fetching one
/// never claims a ride or touches the ride/join-code tables, and the caller
/// still runs its own unchanged create-ride flow with the returned GPX.
class FetchedPlan {
  const FetchedPlan({required this.name, required this.gpx});

  final String? name;
  final String gpx;
}

class PlanDirectoryException implements Exception {
  const PlanDirectoryException(this.message, {this.retryable = false});

  final String message;
  final bool retryable;

  @override
  String toString() => 'PlanDirectoryException: $message';
}

abstract interface class PlanDirectory {
  Future<FetchedPlan> fetch(String code);
}

class HttpPlanDirectory implements PlanDirectory {
  factory HttpPlanDirectory.fromEnvironment() => HttpPlanDirectory(
    configuration: InternetRelayConfiguration.fromEnvironment(),
    client: http.Client(),
  );

  factory HttpPlanDirectory({
    required InternetRelayConfiguration configuration,
    required http.Client client,
  }) => HttpPlanDirectory._(configuration, client);

  HttpPlanDirectory._(this.configuration, this._client);

  final InternetRelayConfiguration configuration;
  final http.Client _client;

  // Matches the server's maximum_plan_bytes default and the mobile GpxParser's
  // own 10 MB import limit - a plan response is a full GPX file, not a small
  // event payload, so it needs a much larger bound than the relay's other
  // lookups.
  static const _maximumResponseBytes = 11 * 1024 * 1024;

  @override
  Future<FetchedPlan> fetch(String code) async {
    final configurationError = configuration.configurationError;
    if (configurationError != null) {
      throw PlanDirectoryException(configurationError);
    }
    final normalisedCode = _normalise(code);
    final response = await _send(
      http.Request('GET', _planUri(normalisedCode))
        ..followRedirects = false
        ..headers['accept'] = 'application/json',
    );
    final body = await _readBoundedResponse(response);
    if (response.statusCode == 404) {
      throw const PlanDirectoryException(
        'That plan code was not found. It may have expired.',
      );
    }
    if (response.statusCode != 200) {
      throw PlanDirectoryException(
        'Plan service returned HTTP ${response.statusCode}.',
        retryable: response.statusCode >= 500,
      );
    }
    final contentType = response.headers['content-type']?.toLowerCase();
    if (contentType == null || !contentType.contains('application/json')) {
      throw const PlanDirectoryException(
        'Plan service returned an invalid response.',
      );
    }
    try {
      final value = jsonDecode(utf8.decode(body));
      if (value is! Map) {
        throw const FormatException('Response is not an object.');
      }
      final json = Map<String, Object?>.from(value);
      final gpx = json['gpx'];
      final name = json['name'];
      if (gpx is! String || gpx.isEmpty) {
        throw const FormatException('Response gpx field is invalid.');
      }
      if (name != null && name is! String) {
        throw const FormatException('Response name field is invalid.');
      }
      return FetchedPlan(name: name as String?, gpx: gpx);
    } on FormatException {
      throw const PlanDirectoryException(
        'Plan service returned an invalid response.',
      );
    } on Object catch (error) {
      throw PlanDirectoryException(
        'Plan service returned an invalid response: $error',
      );
    }
  }

  Future<http.StreamedResponse> _send(http.BaseRequest request) async {
    try {
      return await _client.send(request).timeout(configuration.headerTimeout);
    } on TimeoutException {
      throw const PlanDirectoryException(
        'Plan service timed out. Check your connection and try again.',
        retryable: true,
      );
    } on http.ClientException catch (error) {
      throw PlanDirectoryException(
        'Plan service is unavailable: ${error.message}',
        retryable: true,
      );
    }
  }

  Future<Uint8List> _readBoundedResponse(http.StreamedResponse response) async {
    final declaredLength = response.contentLength;
    if (declaredLength != null && declaredLength > _maximumResponseBytes) {
      throw const PlanDirectoryException(
        'Plan service returned an oversized response.',
      );
    }
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in response.stream.timeout(
        configuration.bodyTimeout,
      )) {
        if (bytes.length + chunk.length > _maximumResponseBytes) {
          throw const PlanDirectoryException(
            'Plan service returned an oversized response.',
          );
        }
        bytes.add(chunk);
      }
    } on TimeoutException {
      throw const PlanDirectoryException(
        'Plan service timed out. Check your connection and try again.',
        retryable: true,
      );
    }
    return bytes.takeBytes();
  }

  String _normalise(String value) {
    final code = value.trim().toUpperCase();
    if (code.isEmpty ||
        code.length > 16 ||
        !RegExp(r'^[A-Z0-9]+$').hasMatch(code)) {
      throw const PlanDirectoryException('Enter a valid plan code.');
    }
    return code;
  }

  Uri _planUri(String code) {
    final base = configuration.baseUri!;
    final baseText = base.toString().endsWith('/')
        ? base.toString().substring(0, base.toString().length - 1)
        : base.toString();
    return Uri.parse('$baseText/v1/plans/${Uri.encodeComponent(code)}');
  }

  void close() => _client.close();
}

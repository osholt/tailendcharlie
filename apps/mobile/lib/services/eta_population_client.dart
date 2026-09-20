import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class EtaPopulationClient {
  EtaPopulationClient({
    required this.baseUri,
    http.Client? client,
    FlutterSecureStorage? storage,
  }) : _client = client ?? http.Client(),
       _storage = storage ?? const FlutterSecureStorage();
  final Uri? baseUri;
  final http.Client _client;
  final FlutterSecureStorage _storage;
  static const _key = 'anonymous_eta_credential_v1';

  Uri _uri(String resource) {
    final baseUri = this.baseUri;
    if (baseUri == null) {
      throw StateError('Relay is not configured');
    }
    return baseUri.replace(
      path: '${baseUri.path.replaceFirst(RegExp(r'/$'), '')}/v1/eta/$resource',
      query: null,
      fragment: null,
    );
  }

  Future<Map<String, double>> fetch() async {
    final response = await _client
        .get(_uri('factors'))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw const FormatException('ETA trends unavailable');
    }
    final data = jsonDecode(response.body) as Map;
    if (data['schemaVersion'] != 1 ||
        data['minimumContributors'] is! num ||
        (data['minimumContributors'] as num) < 20) {
      throw const FormatException('Unsupported ETA trends');
    }
    final factors = data['factors'];
    if (factors is! Map) throw const FormatException('Invalid ETA trends');
    return {
      for (final band in ['urban', 'mixed', 'open'])
        if (factors[band] case final num value
            when value.isFinite && value >= .85 && value <= 1.15)
          band: value.toDouble(),
    };
  }

  Future<void> replace(Map<String, double> bands) async {
    var credential = await _storage.read(key: _key);
    if (credential == null) {
      final random = Random.secure();
      credential =
          'eta1_${base64Url.encode(List.generate(32, (_) => random.nextInt(256))).replaceAll('=', '')}';
      await _storage.write(key: _key, value: credential);
    }
    final response = await _client
        .post(
          _uri('profile'),
          headers: {
            'authorization': 'Eta $credential',
            'content-type': 'application/json',
          },
          body: jsonEncode({
            'schemaVersion': 1,
            'consentVersion': '2026-09-v1',
            'bands': bands,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw const FormatException('ETA contribution not saved');
    }
  }

  Future<void> revoke() async {
    final credential = await _storage.read(key: _key);
    if (credential == null) return;
    final response = await _client
        .delete(_uri('profile'), headers: {'authorization': 'Eta $credential'})
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw const FormatException('ETA contribution removal pending');
    }
    await _storage.delete(key: _key);
  }

  void close() => _client.close();
}

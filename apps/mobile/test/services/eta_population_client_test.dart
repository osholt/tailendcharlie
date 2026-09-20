import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/services/eta_population_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'contribution sends only coarse ratios; deletion uses the same private credential',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final requests = <http.Request>[];
      final client = EtaPopulationClient(
        baseUri: Uri.parse('https://relay.test/api'),
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 200);
        }),
      );
      await client.replace({'mixed': .9});
      final payload = jsonDecode(requests.first.body);
      expect(payload, {
        'schemaVersion': 1,
        'consentVersion': '2026-09-v1',
        'bands': {'mixed': .9},
      });
      expect(requests.first.url.path, '/api/v1/eta/profile');
      expect(requests.first.headers['authorization'], startsWith('Eta eta1_'));
      await client.revoke();
      expect(requests.last.method, 'DELETE');
      expect(
        requests.last.headers['authorization'],
        requests.first.headers['authorization'],
      );
      await client.revoke();
      expect(
        requests,
        hasLength(2),
        reason: 'acknowledged removal clears credential',
      );
      client.close();
    },
  );
  test('insufficient cohorts and extreme factors cannot influence ETA', () async {
    final client = EtaPopulationClient(
      baseUri: Uri.parse('https://relay.test/api'),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'schemaVersion': 1,
            'minimumContributors': 20,
            'factors': {'mixed': .3, 'open': 1.1},
          }),
          200,
        ),
      ),
    );
    expect(await client.fetch(), {'open': 1.1});
    client.close();
    final sparse = EtaPopulationClient(
      baseUri: Uri.parse('https://relay.test/api'),
      client: MockClient(
        (_) async => http.Response(
          '{"schemaVersion":1,"minimumContributors":2,"factors":{"mixed":0.9}}',
          200,
        ),
      ),
    );
    await expectLater(sparse.fetch(), throwsFormatException);
    sparse.close();
  });
}

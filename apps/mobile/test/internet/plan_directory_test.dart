import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/internet/plan_directory.dart';

void main() {
  group('HttpPlanDirectory', () {
    HttpPlanDirectory directoryFor(
      Future<http.Response> Function(http.Request) handler,
    ) => HttpPlanDirectory(
      configuration: InternetRelayConfiguration(
        baseUri: Uri.parse('https://relay.example/base'),
      ),
      client: MockClient(handler),
    );

    test('fetches and decodes a plan by code', () async {
      http.Request? sent;
      final directory = directoryFor((request) async {
        sent = request;
        return http.Response(
          jsonEncode({
            'code': 'ABC12345',
            'name': 'Sunday loop',
            'gpx': '<gpx></gpx>',
            'createdAt': '2026-01-01T00:00:00Z',
            'expiresAt': '2026-02-01T00:00:00Z',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final plan = await directory.fetch('abc12345');

      expect(plan.name, 'Sunday loop');
      expect(plan.gpx, '<gpx></gpx>');
      expect(sent!.method, 'GET');
      expect(sent!.url.path, '/base/v1/plans/ABC12345');
      expect(sent!.followRedirects, isFalse);
      directory.close();
    });

    test('a plan with no name decodes to a null name', () async {
      final directory = directoryFor((request) async {
        return http.Response(
          jsonEncode({
            'code': 'ABC12345',
            'name': null,
            'gpx': '<gpx></gpx>',
            'createdAt': '2026-01-01T00:00:00Z',
            'expiresAt': '2026-02-01T00:00:00Z',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final plan = await directory.fetch('ABC12345');

      expect(plan.name, isNull);
      directory.close();
    });

    test('a 404 raises a clear not-found error', () async {
      final directory = directoryFor(
        (request) async => http.Response(
          jsonEncode({'error': 'Plan not found'}),
          404,
          headers: {'content-type': 'application/json'},
        ),
      );

      await expectLater(
        directory.fetch('ABC12345'),
        throwsA(
          isA<PlanDirectoryException>().having(
            (error) => error.message,
            'message',
            contains('not found'),
          ),
        ),
      );
      directory.close();
    });

    test('a 5xx is reported as retryable', () async {
      final directory = directoryFor((request) async => http.Response('', 503));

      await expectLater(
        directory.fetch('ABC12345'),
        throwsA(
          isA<PlanDirectoryException>().having(
            (error) => error.retryable,
            'retryable',
            isTrue,
          ),
        ),
      );
      directory.close();
    });

    test('a non-JSON content type is rejected', () async {
      final directory = directoryFor(
        (request) async => http.Response(
          '<gpx></gpx>',
          200,
          headers: {'content-type': 'text/plain'},
        ),
      );

      await expectLater(
        directory.fetch('ABC12345'),
        throwsA(isA<PlanDirectoryException>()),
      );
      directory.close();
    });

    test('a response missing the gpx field is rejected', () async {
      final directory = directoryFor(
        (request) async => http.Response(
          jsonEncode({'code': 'ABC12345', 'name': null}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );

      await expectLater(
        directory.fetch('ABC12345'),
        throwsA(isA<PlanDirectoryException>()),
      );
      directory.close();
    });

    test('rejects an invalid code without making a network call', () async {
      var called = false;
      final directory = directoryFor((request) async {
        called = true;
        return http.Response('', 200);
      });

      await expectLater(
        directory.fetch('not a valid code!'),
        throwsA(isA<PlanDirectoryException>()),
      );
      expect(called, isFalse);
      directory.close();
    });

    test('an oversized response is rejected', () async {
      // http.Response derives contentLength from the real body bytes, not
      // from a hand-set header, so the body must actually be this large.
      final oversizedGpx = 'x' * (12 * 1024 * 1024);
      final directory = directoryFor(
        (request) async => http.Response(
          jsonEncode({'gpx': oversizedGpx}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );

      await expectLater(
        directory.fetch('ABC12345'),
        throwsA(isA<PlanDirectoryException>()),
      );
      directory.close();
    });

    test('an unconfigured relay is rejected without a network call', () async {
      var called = false;
      final directory = HttpPlanDirectory(
        configuration: const InternetRelayConfiguration(baseUri: null),
        client: MockClient((request) async {
          called = true;
          return http.Response('', 200);
        }),
      );

      await expectLater(
        directory.fetch('ABC12345'),
        throwsA(isA<PlanDirectoryException>()),
      );
      expect(called, isFalse);
      directory.close();
    });
  });
}

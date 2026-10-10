import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/quick_message.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/internet/internet_cursor_store.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/internet/internet_relay_worker.dart';
import 'package:ride_relay/services/nearby_bridge.dart';

/// The per-platform minimum app build (#37): how a build reads the relay's
/// verdict, what each skew combination does, and that a refused build keeps
/// every local safety record intact.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RelayClientDescriptor build number', () {
    test('reads a plain build number and nothing else', () {
      expect(_descriptor(build: '98').buildNumber, 98);
      for (final unreadable in [
        'unknown',
        '',
        '0',
        '098',
        '1.0.1+22',
        '98a',
        '-4',
      ]) {
        expect(_descriptor(build: unreadable).buildNumber, isNull);
      }
    });

    test('is below a minimum only when both are known and it is lower', () {
      expect(_descriptor(build: '98').isBelowMinimumBuild(103), isTrue);
      expect(_descriptor(build: '103').isBelowMinimumBuild(103), isFalse);
      expect(_descriptor(build: '104').isBelowMinimumBuild(103), isFalse);
      expect(_descriptor(build: '98').isBelowMinimumBuild(null), isFalse);
      expect(_descriptor(build: 'unknown').isBelowMinimumBuild(103), isFalse);
    });
  });

  group('compatibility document', () {
    Future<RelayCompatibilityResult> check(
      Object? minimumClientBuilds, {
      RelayClientDescriptor? descriptor,
      bool includeField = true,
      int minimumClientProtocol = 1,
    }) {
      final client = HttpInternetRelayClient(
        configuration: _configuration,
        client: MockClient(
          (_) async => _document(
            minimumClientBuilds: minimumClientBuilds,
            includeField: includeField,
            minimumClientProtocol: minimumClientProtocol,
          ),
        ),
        clientDescriptor: descriptor ?? _descriptor(build: '98'),
        clock: () => _now,
      );
      addTearDown(client.close);
      return client.checkCompatibility();
    }

    test(
      'a build below the platform minimum is told to update, by number',
      () async {
        final result = await check({'iOS': 103});

        expect(
          result.disposition,
          RelayCompatibilityDisposition.updateRequired,
        );
        expect(result.canSynchronize, isFalse);
        expect(result.minimumClientBuild, 103);
        expect(result.clientBuild, 98);
        expect(result.message, contains('Build 98'));
        expect(result.message, contains('103'));
        expect(
          result.updateUri,
          Uri.parse('https://tailendcharlie.app/update'),
        );
      },
    );

    test('the minimum itself and anything above it are accepted', () async {
      for (final build in ['103', '104', '500']) {
        final result = await check({
          'iOS': 103,
        }, descriptor: _descriptor(build: build));
        expect(
          result.disposition,
          RelayCompatibilityDisposition.compatible,
          reason: 'build $build',
        );
      }
    });

    test(
      'current app and old relay: no field means no build is refused',
      () async {
        final result = await check(null, includeField: false);

        expect(result.disposition, RelayCompatibilityDisposition.compatible);
        expect(result.minimumClientBuild, isNull);
      },
    );

    test(
      'current app and a relay with no compatibility document stays legacy',
      () async {
        final client = HttpInternetRelayClient(
          configuration: _configuration,
          client: MockClient((_) async => http.Response('', 404)),
          clientDescriptor: _descriptor(build: '98'),
          clock: () => _now,
        );
        addTearDown(client.close);

        final result = await client.checkCompatibility();

        expect(
          result.disposition,
          RelayCompatibilityDisposition.legacyCompatible,
        );
        expect(result.canSynchronize, isTrue);
      },
    );

    test(
      'an empty map, and a minimum for another platform, refuse nothing',
      () async {
        for (final minimums in [
          <String, Object?>{},
          {'android': 500},
        ]) {
          final result = await check(minimums);
          expect(
            result.disposition,
            RelayCompatibilityDisposition.compatible,
            reason: '$minimums',
          );
        }
      },
    );

    test(
      'malformed entries are ignored rather than failing the document',
      () async {
        for (final minimums in <Object?>[
          {'iOS': '103'},
          {'iOS': 0},
          {'iOS': -5},
          {'iOS': 103.5},
          {
            'iOS': [103],
          },
          [103],
          'iOS',
        ]) {
          final result = await check(minimums);
          expect(
            result.disposition,
            RelayCompatibilityDisposition.compatible,
            reason: '$minimums',
          );
          expect(result.minimumClientBuild, isNull, reason: '$minimums');
        }
      },
    );

    test('an unstamped build is never judged against a minimum', () async {
      final result = await check({
        'iOS': 103,
      }, descriptor: _descriptor(build: 'unknown'));

      expect(result.disposition, RelayCompatibilityDisposition.compatible);
    });

    test(
      'the protocol cutoff is unchanged and keeps its own wording',
      () async {
        final result = await check(null, minimumClientProtocol: 2);

        expect(
          result.disposition,
          RelayCompatibilityDisposition.updateRequired,
        );
        expect(result.message, isNot(contains('Build 98')));
        expect(result.minimumClientBuild, isNull);
      },
    );
  });

  group('ride-code directory', () {
    test(
      'refuses a retired build before any ride-code call, naming the update',
      () async {
        final requests = <http.Request>[];
        final directory = HttpRideCodeDirectory(
          configuration: _configuration,
          client: MockClient((request) async {
            requests.add(request);
            return _document(minimumClientBuilds: {'iOS': 103});
          }),
          clientDescriptor: _descriptor(build: '98'),
          clock: () => _now,
        );
        addTearDown(directory.close);

        await expectLater(
          directory.resolve('123456'),
          throwsA(
            isA<RideCodeDirectoryException>()
                .having((e) => e.updateRequired, 'updateRequired', isTrue)
                .having((e) => e.message, 'message', contains('Build 98')),
          ),
        );
        expect(
          requests.map((request) => request.url.path),
          everyElement(endsWith('/v1/compatibility')),
          reason:
              'no join-code request may be made for a build the relay refuses',
        );
      },
    );

    test(
      'a 426 from the join-code endpoint itself is an update request too',
      () async {
        final directory = HttpRideCodeDirectory(
          configuration: _configuration,
          client: MockClient((request) async {
            if (request.url.path.endsWith('/v1/compatibility')) {
              // A stale or older document: the build looks fine here.
              return _document(minimumClientBuilds: null, includeField: false);
            }
            return http.Response(
              jsonEncode({
                'code': 'update_required',
                'message':
                    'This version of Tail End Charlie is no longer supported.',
                'updateUrl': 'https://tailendcharlie.app/update',
              }),
              426,
              headers: {'content-type': 'application/json'},
            );
          }),
          clientDescriptor: _descriptor(build: '98'),
          clock: () => _now,
        );
        addTearDown(directory.close);

        await expectLater(
          directory.resolve('123456'),
          throwsA(
            isA<RideCodeDirectoryException>().having(
              (e) => e.updateRequired,
              'updateRequired',
              isTrue,
            ),
          ),
        );
      },
    );

    test('an ordinary directory failure is not an update request', () async {
      final directory = HttpRideCodeDirectory(
        configuration: _configuration,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/v1/compatibility')) {
            return _document(minimumClientBuilds: {'iOS': 90});
          }
          return http.Response('', 404);
        }),
        clientDescriptor: _descriptor(build: '98'),
        clock: () => _now,
      );
      addTearDown(directory.close);

      await expectLater(
        directory.resolve('123456'),
        throwsA(
          isA<RideCodeDirectoryException>().having(
            (e) => e.updateRequired,
            'updateRequired',
            isFalse,
          ),
        ),
      );
    });
  });

  group('RideController join', () {
    test(
      'reports an update request, and clears it on the next attempt',
      () async {
        var minimum = 103;
        final controller = RideController(
          InMemoryEventStore(),
          InMemorySessionStore(),
          NearbyBridge(),
          random: Random(7),
          rideCodeDirectory: HttpRideCodeDirectory(
            configuration: _configuration,
            client: MockClient(
              (_) async => _document(minimumClientBuilds: {'iOS': minimum}),
            ),
            clientDescriptor: _descriptor(build: '98'),
            clock: () => _now,
          ),
        );
        addTearDown(controller.dispose);
        await controller.initialize();

        await controller.joinRide('123456', 'Oliver');

        expect(controller.errorNeedsUpdate, isTrue);
        expect(controller.errorMessage, contains('Build 98'));
        expect(controller.errorIsRetryable, isFalse);
        expect(controller.hasActiveRide, isFalse);

        minimum = 50;
        await controller.joinRide('not-a-code', 'Oliver');

        expect(controller.errorNeedsUpdate, isFalse);
        controller.clearError();
        expect(controller.errorMessage, isNull);
      },
    );
  });

  group('a refused build keeps its ride safe', () {
    test(
      'SOS recorded while the relay refuses this build is kept, never sent '
      'to a relay that refuses it, and is delivered once the gate lifts',
      () async {
        var minimum = 103;
        final syncBodies = <Map<String, Object?>>[];
        final transport = MockClient((request) async {
          if (request.url.path.endsWith('/v1/compatibility')) {
            return _document(minimumClientBuilds: {'iOS': minimum});
          }
          final body = jsonDecode(request.body) as Map<String, Object?>;
          if (minimum > 98) {
            // What the relay does to a build below its minimum: refuse before
            // accepting any ride state.
            return http.Response(
              jsonEncode({
                'code': 'update_required',
                'message':
                    'This version of Tail End Charlie is no longer supported.',
                'updateUrl': 'https://tailendcharlie.app/update',
                'minimumClientBuild': minimum,
              }),
              426,
              headers: {'content-type': 'application/json'},
            );
          }
          syncBodies.add(body);
          final ids = [
            for (final event in body['events']! as List)
              (event as Map)['id'] as String,
          ];
          return http.Response(
            jsonEncode({
              'protocolVersion': 1,
              'cursor': 'cursor-1',
              'acceptedEventIds': ids,
              'events': <Object?>[],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        });
        final events = InMemoryEventStore();
        var id = 0;
        final controller = RideController(
          events,
          InMemorySessionStore(),
          NearbyBridge(),
          clock: () => _now,
          idFactory: () => 'id-${id++}',
          random: Random(7),
          rideCodeDirectory: HttpRideCodeDirectory(
            configuration: _configuration,
            client: transport,
            clientDescriptor: _descriptor(build: '98'),
            clock: () => _now,
          ),
        );
        addTearDown(controller.dispose);
        await controller.initialize();
        await controller.createRide('Oliver');
        await controller.startRide();
        final session = controller.session!;

        final worker = InternetRelayWorker(
          api: HttpInternetRelayClient(
            configuration: _configuration,
            client: transport,
            clientDescriptor: _descriptor(build: '98'),
            clock: () => _now,
          ),
          eventStore: events,
          cursorStore: InMemoryInternetCursorStore(),
          pollInterval: const Duration(hours: 1),
          retryPolicy: const InternetRetryPolicy(
            initialDelay: Duration(hours: 1),
            maximumDelay: Duration(hours: 1),
          ),
        );
        addTearDown(worker.close);
        final blocked = worker.statuses.firstWhere(
          (status) => status.phase == InternetRelayPhase.updateRequired,
        );
        await worker.start(session);
        final status = await blocked.timeout(const Duration(seconds: 2));

        // The gate is up: the app says so, with the update link...
        expect(
          status.actionUrl,
          Uri.parse('https://tailendcharlie.app/update'),
        );
        expect(controller.errorNeedsUpdate, isFalse);

        // ...and the rider raises an SOS exactly as the control does.
        await controller.sendQuickMessage(QuickMessage.emergencyStop);

        expect(controller.errorMessage, isNull);
        final sos = (await events.pendingEvents(session.rideId)).singleWhere(
          (event) =>
              event.type == RideEventType.statusMessage &&
              event.payload['message'] == QuickMessage.emergencyStop.name,
        );
        expect(sos.priority, EventPriority.critical);
        expect(syncBodies, isEmpty);

        // A refused attempt does not quarantine, drop or acknowledge it.
        await worker.synchronizeNow();
        expect(worker.quarantinedEventIds, isEmpty);
        expect(
          (await events.pendingEvents(session.rideId)).map((e) => e.id),
          contains(sos.id),
        );

        // The operator lowers the minimum (or the rider updates): the same
        // event is delivered, so nothing was lost by the refusal.
        minimum = 90;
        await worker.synchronizeNow();

        expect(syncBodies, isNotEmpty);
        expect(
          syncBodies
              .expand((body) => body['events']! as List)
              .map((event) => (event as Map)['id']),
          contains(sos.id),
        );
        expect(await events.pendingEventCount(session.rideId), 0);
      },
    );
  });
}

final _now = DateTime.utc(2026, 10, 9, 12);

final _configuration = InternetRelayConfiguration(
  baseUri: Uri.parse('https://relay.example'),
);

RelayClientDescriptor _descriptor({
  required String build,
  String platform = 'iOS',
}) => RelayClientDescriptor(
  protocolVersion: 1,
  platform: platform,
  appVersion: '1.0.1',
  appBuild: build,
  capabilities: RelayProtocolCapabilities.current,
  distributionTrack: 'testflight',
);

http.Response _document({
  Object? minimumClientBuilds,
  bool includeField = true,
  int minimumClientProtocol = 1,
}) => http.Response(
  jsonEncode({
    'serverProtocol': 1,
    'minimumClientProtocol': minimumClientProtocol,
    'maximumClientProtocol': 1,
    'capabilities': RelayProtocolCapabilities.current.toList(),
    'requiredCapabilities': <String>[],
    'cacheSeconds': 30,
    'updateUrls': {
      'default': 'https://tailendcharlie.app/update',
      'iOS': 'https://tailendcharlie.app/update',
      'android': 'https://tailendcharlie.app/update',
    },
    if (includeField) 'minimumClientBuilds': minimumClientBuilds,
  }),
  200,
  headers: {'content-type': 'application/json'},
);

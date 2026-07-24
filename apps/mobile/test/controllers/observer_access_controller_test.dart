import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/observer_access_controller.dart';
import 'package:ride_relay/data/observer_grant_store.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/internet/observer_access_client.dart';

void main() {
  test('secure credentials survive a controller restart', () async {
    final store = _MemoryObserverGrantStore();
    final firstApi = _FakeObserverApi();
    final first = ObserverAccessController(firstApi, store, clock: _clock);
    await first.attach(_session);
    await first.create(
      label: 'Home contact',
      duration: const Duration(hours: 4),
    );

    expect(first.latestInvite?.shareUri.fragment, contains('ro1_'));
    expect(store.saved[_session.rideId], hasLength(1));

    final restarted = ObserverAccessController(
      _FakeObserverApi(),
      store,
      clock: _clock,
    );
    await restarted.attach(_session);
    expect(restarted.grants.single.label, 'Home contact');
  });

  test(
    'rapid locations coalesce to one in-flight and one latest snapshot',
    () async {
      final store = _MemoryObserverGrantStore();
      final api = _FakeObserverApi(delayFirstPublish: true);
      final controller = ObserverAccessController(
        api,
        store,
        clock: _clock,
        publishInterval: Duration.zero,
      );
      await controller.attach(_session);
      await controller.create(
        label: 'Home',
        duration: const Duration(hours: 4),
      );

      controller.publishSnapshot(_snapshot(0));
      await api.firstPublishStarted.future;
      for (var index = 1; index < 100; index += 1) {
        controller.publishSnapshot(_snapshot(index));
      }
      api.releaseFirstPublish.complete();
      await controller.waitForPendingPublishes();

      expect(api.published, hasLength(2));
      expect(api.published.last.position?.latitude, 99);
    },
  );

  test(
    'delayed unavailable publish cannot erase a concurrently created grant',
    () async {
      final store = _MemoryObserverGrantStore();
      final api = _FakeObserverApi(
        delayFirstPublish: true,
        failFirstPublishUnavailable: true,
      );
      final controller = ObserverAccessController(api, store, clock: _clock);
      await controller.attach(_session);
      await controller.create(
        label: 'First',
        duration: const Duration(hours: 4),
      );

      controller.publishSnapshot(_snapshot(1));
      await api.firstPublishStarted.future;
      await controller.create(
        label: 'Second',
        duration: const Duration(hours: 4),
      );
      api.releaseFirstPublish.complete();
      await controller.waitForPendingPublishes();

      expect(controller.grants.map((grant) => grant.label), ['Second']);
      expect(store.saved[_session.rideId]?.single.grant.label, 'Second');
    },
  );

  test(
    'snapshot generation time remains monotonic when the clock stalls',
    () async {
      final controller = ObserverAccessController(
        _FakeObserverApi(),
        _MemoryObserverGrantStore(),
        clock: _clock,
      );
      final first = controller.nextSnapshotGeneratedAt();
      final second = controller.nextSnapshotGeneratedAt();
      expect(second.isAfter(first), isTrue);
    },
  );

  test('delayed publish cannot restore a concurrently revoked grant', () async {
    final store = _MemoryObserverGrantStore();
    final api = _FakeObserverApi(delayFirstPublish: true);
    final controller = ObserverAccessController(api, store, clock: _clock);
    await controller.attach(_session);
    await controller.create(label: 'Home', duration: const Duration(hours: 4));

    controller.publishSnapshot(_snapshot(1));
    await api.firstPublishStarted.future;
    await controller.revoke('grant-1');
    api.releaseFirstPublish.complete();
    await controller.waitForPendingPublishes();

    expect(controller.grants, isEmpty);
    expect(store.saved[_session.rideId], isNull);
  });

  test('routine fast samples are rate bounded and latest wins', () async {
    final store = _MemoryObserverGrantStore();
    final api = _FakeObserverApi();
    final controller = ObserverAccessController(api, store, clock: _clock);
    await controller.attach(_session);
    await controller.create(label: 'Home', duration: const Duration(hours: 4));

    for (var index = 0; index < 100; index += 1) {
      controller.publishSnapshot(_snapshot(index, routine: true));
    }
    await controller.waitForPendingPublishes();
    expect(api.published, hasLength(1));

    await controller.flushPendingSnapshot();
    expect(api.published, hasLength(2));
    expect(api.published.last.position?.latitude, 99);
  });

  test(
    'stationary critical snapshot retries after a transient failure',
    () async {
      final store = _MemoryObserverGrantStore();
      final api = _FakeObserverApi(failFirstPublishRetryable: true);
      final controller = ObserverAccessController(api, store, clock: _clock);
      await controller.attach(_session);
      await controller.create(
        label: 'Home',
        duration: const Duration(hours: 4),
      );
      final critical = _snapshot(1);

      controller.publishSnapshot(critical);
      await controller.waitForPendingPublishes();
      expect(api.published, [critical]);

      await controller.flushPendingSnapshot();
      expect(api.published, [critical, critical]);
    },
  );

  test(
    'local assistance and its explicit resolution survive restart',
    () async {
      final store = _MemoryObserverGrantStore();
      final controller = ObserverAccessController(
        _FakeObserverApi(),
        store,
        clock: _clock,
      );
      await controller.attach(_session);
      await controller.create(
        label: 'Home',
        duration: const Duration(hours: 4),
      );
      await controller.recordLocalAssistance('assistance');

      final restarted = ObserverAccessController(
        _FakeObserverApi(),
        store,
        clock: _clock,
      );
      await restarted.attach(_session);
      expect(restarted.localAssistance?.kind, 'assistance');

      await restarted.recordLocalAssistance(null);
      final afterResolution = ObserverAccessController(
        _FakeObserverApi(),
        store,
        clock: _clock,
      );
      await afterResolution.attach(_session);
      expect(afterResolution.localAssistance, isNull);
      expect(
        afterResolution.localAssistanceUpdatedAt.isAfter(
          DateTime.utc(2026, 7, 24, 13),
        ),
        isTrue,
      );
    },
  );
}

DateTime _clock() => DateTime.utc(2026, 7, 24, 13);

final _session = RideSession(
  rideId: 'ride-observer',
  rideCode: '123456',
  inviteSecret: 'observer-secret-0123456789012345',
  joinToken: 'join-token-0123456789',
  localRiderId: 'rider-a',
  displayName: 'Oliver',
  role: RideRole.rider,
  joinedAt: DateTime.utc(2026, 7, 24),
);

ObserverPublishedSnapshot _snapshot(int sequence, {bool routine = false}) {
  final timestamp = DateTime.utc(2026, 7, 24, 12, 0, sequence);
  final componentTimestamp = routine
      ? DateTime.utc(2026, 7, 24, 12)
      : timestamp;
  return ObserverPublishedSnapshot(
    subjectName: 'Oliver',
    snapshotGeneratedAt: timestamp,
    rideStatus: 'active',
    statusUpdatedAt: componentTimestamp,
    assistanceUpdatedAt: componentTimestamp,
    position: ObserverPublishedPosition(
      latitude: sequence.toDouble(),
      longitude: -1,
      accuracyMeters: 5,
      recordedAt: timestamp,
    ),
  );
}

class _MemoryObserverGrantStore implements ObserverGrantStore {
  final saved = <String, List<ObserverGrantCredentials>>{};
  final assistance = <String, ObserverLocalAssistanceState>{};

  @override
  Future<void> delete(String rideId) async => saved.remove(rideId);

  @override
  Future<void> deleteLocalAssistance(String rideId) async =>
      assistance.remove(rideId);

  @override
  Future<List<ObserverGrantCredentials>> load(String rideId) async =>
      List.of(saved[rideId] ?? const []);

  @override
  Future<ObserverLocalAssistanceState?> loadLocalAssistance(
    String rideId,
  ) async => assistance[rideId];

  @override
  Future<void> save(
    String rideId,
    List<ObserverGrantCredentials> credentials,
  ) async {
    saved[rideId] = List.of(credentials);
  }

  @override
  Future<void> saveLocalAssistance(
    String rideId,
    ObserverLocalAssistanceState state,
  ) async => assistance[rideId] = state;
}

class _FakeObserverApi implements ObserverAccessApi {
  _FakeObserverApi({
    this.delayFirstPublish = false,
    this.failFirstPublishUnavailable = false,
    this.failFirstPublishRetryable = false,
  });

  final bool delayFirstPublish;
  final bool failFirstPublishUnavailable;
  final bool failFirstPublishRetryable;
  final firstPublishStarted = Completer<void>();
  final releaseFirstPublish = Completer<void>();
  final published = <ObserverPublishedSnapshot>[];
  var _nextGrant = 0;

  @override
  final configuration = ObserverAccessConfiguration(
    relay: InternetRelayConfiguration(
      baseUri: Uri.parse('https://relay.example/api'),
    ),
    webBaseUri: Uri.parse('https://relay.example/observer.html'),
  );

  @override
  Future<ObserverGrantCredentials> create(
    RideSession session, {
    required String label,
    required Duration duration,
  }) async {
    _nextGrant += 1;
    return ObserverGrantCredentials(
      grant: ObserverGrant(
        id: 'grant-$_nextGrant',
        label: label,
        createdAt: _clock(),
        expiresAt: _clock().add(duration),
      ),
      managementToken: 'om1_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      publisherToken: 'op1_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
      observerToken: 'ro1_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC',
    );
  }

  @override
  Future<ObserverGrant> inspect(ObserverGrantCredentials credentials) async =>
      credentials.grant;

  @override
  Future<void> publish(
    ObserverGrantCredentials credentials,
    ObserverPublishedSnapshot snapshot,
  ) async {
    published.add(snapshot);
    if (published.length == 1 && failFirstPublishRetryable) {
      throw const InternetRelayException(
        'Temporary outage',
        retryable: true,
        statusCode: 503,
      );
    }
    if (published.length == 1 && delayFirstPublish) {
      firstPublishStarted.complete();
      await releaseFirstPublish.future;
      if (failFirstPublishUnavailable) {
        throw const InternetRelayException('Unavailable', statusCode: 404);
      }
    }
  }

  @override
  Future<void> revoke(ObserverGrantCredentials credentials) async {}

  @override
  Uri shareUri(ObserverGrantCredentials credentials) =>
      configuration.webBaseUri!.replace(
        fragment: '${credentials.grant.id}.${credentials.observerToken}',
      );

  @override
  void close() {}
}

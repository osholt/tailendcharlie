import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/observer_access_controller.dart';
import 'package:ride_relay/data/observer_grant_store.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/ride/observer_access_sheet.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/internet/observer_access_client.dart';

void main() {
  testWidgets('explains the narrow disclosure and requires explicit consent', (
    tester,
  ) async {
    final api = _FakeObserverApi();
    final controller = ObserverAccessController(api, _MemoryStore());
    await controller.attach(_session);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(body: ObserverAccessSheet(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('last-known position'), findsOneWidget);
    expect(find.textContaining('does not share the ride code'), findsOneWidget);
    expect(find.textContaining('not proof that you are safe'), findsOneWidget);
    FilledButton createButton = tester.widget(
      find.byKey(const Key('create-observer-link')),
    );
    expect(createButton.onPressed, isNull);

    await tester.tap(find.byKey(const Key('observer-consent')));
    await tester.pump();
    createButton = tester.widget(find.byKey(const Key('create-observer-link')));
    expect(createButton.onPressed, isNotNull);

    await tester.tap(find.byKey(const Key('create-observer-link')));
    await tester.pumpAndSettle();

    expect(api.createCount, 1);
    expect(find.text('Link ready'), findsOneWidget);
    expect(find.text('Revoke'), findsOneWidget);
  });
}

final _session = RideSession(
  rideId: 'ride-observer',
  rideCode: '123456',
  inviteSecret: 'observer-secret-0123456789012345',
  joinToken: 'join-token-0123456789',
  localRiderId: 'rider-a',
  displayName: 'Oliver',
  role: RideRole.rider,
  joinedAt: DateTime(2026, 7, 24),
);

class _FakeObserverApi implements ObserverAccessApi {
  int createCount = 0;

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
    createCount += 1;
    return ObserverGrantCredentials(
      grant: ObserverGrant(
        id: 'grant-a',
        label: label,
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(duration),
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
  ) async {}

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

class _MemoryStore implements ObserverGrantStore {
  List<ObserverGrantCredentials> values = const [];
  ObserverLocalAssistanceState? assistance;

  @override
  Future<void> delete(String rideId) async => values = const [];

  @override
  Future<void> deleteLocalAssistance(String rideId) async => assistance = null;

  @override
  Future<List<ObserverGrantCredentials>> load(String rideId) async => values;

  @override
  Future<ObserverLocalAssistanceState?> loadLocalAssistance(
    String rideId,
  ) async => assistance;

  @override
  Future<void> save(
    String rideId,
    List<ObserverGrantCredentials> credentials,
  ) async => values = List.of(credentials);

  @override
  Future<void> saveLocalAssistance(
    String rideId,
    ObserverLocalAssistanceState state,
  ) async => assistance = state;
}

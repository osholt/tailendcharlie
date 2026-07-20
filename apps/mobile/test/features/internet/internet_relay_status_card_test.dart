import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/internet_relay_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/internet/internet_relay_status_card.dart';
import 'package:ride_relay/internet/internet_cursor_store.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/internet/internet_relay_worker.dart';

void main() {
  testWidgets('makes unconfigured state explicit without implying live sync', (
    tester,
  ) async {
    final controller = InternetRelayController(
      InternetRelayWorker(
        api: _UnconfiguredApi(),
        eventStore: InMemoryEventStore(),
        cursorStore: InMemoryInternetCursorStore(),
      ),
    );
    await controller.start(_session);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: InternetRelayStatusCard(controller: controller)),
      ),
    );

    expect(find.text('Internet relay not configured'), findsOneWidget);
    expect(
      find.text('Set RIDE_RELAY_API_BASE_URL · no server traffic'),
      findsOneWidget,
    );
    expect(find.textContaining('live'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(controller.close);
  });
}

class _UnconfiguredApi implements InternetRelayApi {
  @override
  InternetRelayConfiguration get configuration =>
      const InternetRelayConfiguration(baseUri: null);

  @override
  Future<InternetSyncResult> synchronize({
    required RideSession session,
    required String? cursor,
    required List<RideEvent> events,
  }) => throw StateError('Unconfigured API must not be called.');

  @override
  void close() {}
}

final _session = RideSession(
  rideId: 'ride-alpha',
  rideCode: 'ALPHA1',
  inviteSecret: '0123456789abcdef0123456789abcdef',
  joinToken: 'test-join-token-0123456789',
  localRiderId: 'local-device',
  displayName: 'Oliver',
  role: RideRole.rider,
  joinedAt: DateTime.utc(2026, 7, 16),
);

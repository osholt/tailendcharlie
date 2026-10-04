import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/nearby_relay_controller.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/ride/ride_roster_sheet.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/relay/in_memory_relay_queue.dart';
import 'package:ride_relay/relay/peer_transport.dart';
import 'package:ride_relay/relay/relay_engine.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';
import 'package:ride_relay/services/transport_evidence_ledger.dart';

/// #855: the roster says, for each rider, which route last delivered from them.
///
/// The operator's question was "was that the phone signal or actual P2P sharing?"
/// A rider whose Bluetooth line is fresh while their internet line is old is
/// being carried by the direct link, and this is where a rider can see that.
void main() {
  final startedAt = DateTime.utc(2026, 10, 4, 10);

  /// The moment the roster is read at. Pinned, so "12 s ago" is 12 whatever the
  /// machine's speed.
  final readAt = DateTime.utc(2026, 10, 4, 10, 30);
  late InMemoryEventStore eventStore;
  late RideController controller;
  late TransportEvidenceLedger ledger;

  setUp(() async {
    eventStore = InMemoryEventStore();
    var id = 0;
    controller = RideController(
      eventStore,
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      clock: () => startedAt.add(const Duration(minutes: 5)),
      idFactory: () => 'id-${(id++).toString().padLeft(3, '0')}',
      random: Random(5),
      rideCodeDirectory: _NullRideCodeDirectory(),
    );
    await controller.initialize();
    await controller.createRide('Oliver');
    final session = controller.session!;
    for (final rider in ['alex', 'sam']) {
      await eventStore.append(
        _signed(
          session: session,
          id: 'join-$rider',
          deviceId: rider,
          type: RideEventType.riderJoined,
          createdAt: startedAt,
          payload: {
            'displayName': rider == 'alex' ? 'Alex' : 'Sam',
            'role': 'rider',
          },
        ),
      );
    }
    await controller.reloadEvents();
    ledger = TransportEvidenceLedger(localRiderId: session.localRiderId);
  });

  tearDown(() => controller.dispose());

  /// Tall enough that every row is built: the roster is a lazy list, and rows
  /// below the fold are not in the tree to be found.
  void tallWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget harness({
    TransportEvidenceLedger? evidence,
    NearbyRelayController? nearby,
  }) => MaterialApp(
    home: Scaffold(
      body: RideRosterSheet(
        controller: controller,
        transportEvidence: evidence,
        nearbyRelayController: nearby,
        clock: () => readAt,
      ),
    ),
  );

  Text subtitleOf(WidgetTester tester, String riderId) => tester.widget<Text>(
    find.descendant(
      of: find.byKey(Key('roster-rider-$riderId')),
      matching: find.textContaining('Last seen'),
    ),
  );

  group('the line under each rider', () {
    testWidgets('says when each route last delivered from them', (
      tester,
    ) async {
      tallWindow(tester);
      final now = readAt;
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: 'alex',
        at: now.subtract(const Duration(seconds: 12)),
      );
      ledger.recordPresence(
        transport: EvidenceTransport.internet,
        riderId: 'alex',
        at: now.subtract(const Duration(seconds: 8)),
      );

      await tester.pumpWidget(harness(evidence: ledger));
      await tester.pumpAndSettle();

      expect(
        subtitleOf(tester, 'alex').data,
        contains('Bluetooth 12 s ago · Internet 8 s ago'),
      );
    });

    testWidgets('says "nothing yet" for a route that has delivered nothing', (
      tester,
    ) async {
      tallWindow(tester);
      ledger.recordPresence(
        transport: EvidenceTransport.internet,
        riderId: 'alex',
        at: readAt.subtract(const Duration(seconds: 8)),
      );

      await tester.pumpWidget(harness(evidence: ledger));
      await tester.pumpAndSettle();

      expect(
        subtitleOf(tester, 'alex').data,
        contains('Bluetooth: nothing yet · Internet 8 s ago'),
      );
    });

    testWidgets('says so for a rider nothing has been heard from', (
      tester,
    ) async {
      tallWindow(tester);
      await tester.pumpWidget(harness(evidence: ledger));
      await tester.pumpAndSettle();

      expect(
        subtitleOf(tester, 'sam').data,
        contains('Bluetooth: nothing yet · Internet: nothing yet'),
      );
    });

    testWidgets('tells two riders apart', (tester) async {
      tallWindow(tester);
      final now = readAt;
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: 'alex',
        at: now.subtract(const Duration(seconds: 3)),
      );
      ledger.recordPresence(
        transport: EvidenceTransport.internet,
        riderId: 'sam',
        at: now.subtract(const Duration(seconds: 30)),
      );

      await tester.pumpWidget(harness(evidence: ledger));
      await tester.pumpAndSettle();

      expect(subtitleOf(tester, 'alex').data, contains('Bluetooth 3 s ago'));
      expect(
        subtitleOf(tester, 'alex').data,
        contains('Internet: nothing yet'),
      );
      expect(
        subtitleOf(tester, 'sam').data,
        contains('Bluetooth: nothing yet'),
      );
      expect(subtitleOf(tester, 'sam').data, contains('Internet 30 s ago'));
    });

    testWidgets('is on this phone\'s own row never', (tester) async {
      tallWindow(tester);
      await tester.pumpWidget(harness(evidence: ledger));
      await tester.pumpAndSettle();

      final localId = controller.session!.localRiderId;
      final own = find.byKey(Key('roster-rider-$localId'));
      expect(own, findsOneWidget);
      expect(
        find.descendant(of: own, matching: find.textContaining('Bluetooth')),
        findsNothing,
      );
    });

    testWidgets('is part of the row\'s accessible label', (tester) async {
      tallWindow(tester);
      ledger.recordPresence(
        transport: EvidenceTransport.bluetooth,
        riderId: 'alex',
        at: readAt.subtract(const Duration(seconds: 12)),
      );

      await tester.pumpWidget(harness(evidence: ledger));
      await tester.pumpAndSettle();

      final semantics = tester.getSemantics(
        find.byKey(const Key('roster-rider-alex')),
      );
      expect(semantics.label, contains('Bluetooth 12 s ago'));
    });

    testWidgets('does not appear at all when there is no ledger', (
      tester,
    ) async {
      tallWindow(tester);
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();

      expect(find.textContaining('Bluetooth'), findsNothing);
      expect(find.byKey(const Key('roster-bluetooth-status')), findsNothing);
    });
  });

  group('the ride-level line about the direct link', () {
    late _FakeTransport transport;
    late NearbyRelayController nearby;

    setUp(() {
      transport = _FakeTransport();
      nearby = NearbyRelayController(
        RelayEngine(
          transport: transport,
          eventStore: InMemoryEventStore(),
          queue: InMemoryRelayQueue(),
        ),
      );
    });

    tearDown(() async {
      await nearby.stop();
      await nearby.close();
    });

    Future<void> startNearby(WidgetTester tester) async {
      await tester.runAsync(() async {
        await nearby.start(controller.session!);
        await Future<void>.delayed(Duration.zero);
      });
    }

    testWidgets('says the link is not running when there is no relay', (
      tester,
    ) async {
      tallWindow(tester);
      await tester.pumpWidget(harness(evidence: ledger));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<Text>(find.byKey(const Key('roster-bluetooth-status')))
            .data,
        'Bluetooth: not running on this phone',
      );
    });

    testWidgets('says how many phones it is connected to, and follows it', (
      tester,
    ) async {
      tallWindow(tester);
      await startNearby(tester);
      await tester.pumpWidget(harness(evidence: ledger, nearby: nearby));
      await tester.pump();

      await tester.runAsync(() async {
        transport.emit(
          const PeerTransportStatus(
            state: PeerTransportState.connected,
            peerIds: {'a', 'b'},
          ),
        );
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      expect(
        tester
            .widget<Text>(find.byKey(const Key('roster-bluetooth-status')))
            .data,
        'Bluetooth: connected to 2 phones',
      );

      await tester.runAsync(() async {
        transport.emit(
          const PeerTransportStatus(state: PeerTransportState.searching),
        );
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      expect(
        tester
            .widget<Text>(find.byKey(const Key('roster-bluetooth-status')))
            .data,
        'Bluetooth: searching for nearby phones',
      );
    });

    testWidgets('says why it is unavailable', (tester) async {
      tallWindow(tester);
      await startNearby(tester);
      await tester.pumpWidget(harness(evidence: ledger, nearby: nearby));
      await tester.pump();

      await tester.runAsync(() async {
        transport.emit(
          const PeerTransportStatus(
            state: PeerTransportState.unavailable,
            message: 'Nearby-device permission is required',
          ),
        );
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();

      expect(
        tester
            .widget<Text>(find.byKey(const Key('roster-bluetooth-status')))
            .data,
        'Bluetooth: unavailable: nearby-device permission is needed',
      );
    });
  });
}

RideEvent _signed({
  required RideSession session,
  required String id,
  required String deviceId,
  required RideEventType type,
  required DateTime createdAt,
  required Map<String, Object?> payload,
}) {
  final unsigned = RideEvent(
    id: id,
    rideId: session.rideId,
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: createdAt,
    payload: payload,
    signature: '',
  );
  return RideEvent(
    id: id,
    rideId: session.rideId,
    deviceId: deviceId,
    type: type,
    priority: EventPriority.routine,
    createdAt: createdAt,
    payload: payload,
    signature: RideEventAuthenticator.sign(unsigned, session.inviteSecret),
  );
}

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async =>
      const NearbyCapabilities.unavailable();
}

class _NullRideCodeDirectory implements RideCodeDirectory {
  @override
  Future<void> register(RideSession session) async {}

  @override
  Future<RideCodeCredentials> resolve(
    String rideCode, {
    String? joinToken,
  }) async => throw const RideCodeDirectoryException('Not used in this test.');

  @override
  void close() {}
}

/// A transport whose status the test sets directly.
class _FakeTransport implements PeerTransport {
  final _statuses = StreamController<PeerTransportStatus>.broadcast();
  final _packets = StreamController<PeerPacket>.broadcast();

  void emit(PeerTransportStatus status) => _statuses.add(status);

  @override
  Stream<PeerPacket> get packets => _packets.stream;

  @override
  Stream<PeerTransportStatus> get statuses => _statuses.stream;

  @override
  Future<void> start(PeerTransportConfig config) async {}

  @override
  Future<void> send(Uint8List bytes, {required Set<String> peerIds}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    await _statuses.close();
    await _packets.close();
  }
}

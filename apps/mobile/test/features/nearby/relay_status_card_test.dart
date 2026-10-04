import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/nearby_relay_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/nearby/relay_status_card.dart';
import 'package:ride_relay/relay/in_memory_relay_queue.dart';
import 'package:ride_relay/relay/peer_transport.dart';
import 'package:ride_relay/relay/relay_engine.dart';
import 'package:ride_relay/services/transport_evidence_ledger.dart';

/// #855: the dashboard's Bluetooth card says what the link has received.
///
/// Its line used to read "does not carry ride events yet", which stopped being true
/// when the relay engine shipped and which contradicted the evidence the rest of
/// the app now shows.
void main() {
  final session = RideSession(
    rideId: 'ride-1',
    rideCode: '123456',
    inviteSecret: '0123456789abcdef0123456789abcdef',
    joinToken: 'test-join-token-0123456789',
    localRiderId: 'local',
    displayName: 'Oliver',
    role: RideRole.lead,
    joinedAt: DateTime.utc(2026, 10, 4, 10),
  );
  late _FakeTransport transport;
  late NearbyRelayController nearby;
  late TransportEvidenceLedger ledger;

  setUp(() async {
    transport = _FakeTransport();
    nearby = NearbyRelayController(
      RelayEngine(
        transport: transport,
        eventStore: InMemoryEventStore(),
        queue: InMemoryRelayQueue(),
      ),
    );
    ledger = TransportEvidenceLedger(localRiderId: 'local');
    await nearby.start(session);
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    await nearby.stop();
    await nearby.close();
  });

  Future<void> pumpCard(
    WidgetTester tester, {
    TransportEvidenceLedger? evidence,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RelayStatusCard(controller: nearby, evidence: evidence),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> report(WidgetTester tester, PeerTransportStatus status) async {
    await tester.runAsync(() async {
      transport.emit(status);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
  }

  testWidgets('titles itself with the ride-level line', (tester) async {
    await pumpCard(tester, evidence: ledger);

    await report(
      tester,
      const PeerTransportStatus(
        state: PeerTransportState.connected,
        peerIds: {'a'},
      ),
    );

    expect(find.text('Bluetooth: connected to 1 phone'), findsOneWidget);
  });

  testWidgets('says nothing has been received before anything arrives', (
    tester,
  ) async {
    await pumpCard(tester, evidence: ledger);

    expect(find.text('Nothing received over Bluetooth yet'), findsOneWidget);
  });

  testWidgets('says what has been received, and from how many riders', (
    tester,
  ) async {
    ledger.recordEvent(
      transport: EvidenceTransport.bluetooth,
      eventId: 'e1',
      authorId: 'alex',
    );
    ledger.recordPresence(
      transport: EvidenceTransport.bluetooth,
      riderId: 'sam',
    );

    await pumpCard(tester, evidence: ledger);

    expect(
      find.text('Received over Bluetooth: 2 updates from 2 riders'),
      findsOneWidget,
    );
  });

  testWidgets('no longer says the link does not carry ride events', (
    tester,
  ) async {
    await pumpCard(tester, evidence: ledger);

    expect(find.textContaining('does not carry'), findsNothing);
    expect(find.textContaining('Not carrying'), findsNothing);
  });

  testWidgets('says what is held when there is no ledger to report from', (
    tester,
  ) async {
    await pumpCard(tester);

    expect(find.text('Nothing held for nearby phones'), findsOneWidget);
  });

  testWidgets('names the reason when the link is unavailable', (tester) async {
    await pumpCard(tester, evidence: ledger);

    await report(
      tester,
      const PeerTransportStatus(
        state: PeerTransportState.unavailable,
        message: 'Nearby-device permission is required',
      ),
    );

    expect(
      find.text('Bluetooth: unavailable: nearby-device permission is needed'),
      findsOneWidget,
    );
  });
}

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

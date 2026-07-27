// An interrupting alert must never block the safety controls (#177).
//
//   "I had to ok your messages before I could leave!!"
//
// The interrupt overlay was `Positioned.fill`, opaque, and absorbed every tap, so
// while a critical quick message was up neither LEAVE nor SOS could be pressed -
// one tap per outstanding message before either became reachable. Leave was the
// reported half; SOS was the worse one, and nobody had noticed it.
//
// The invariant asserted here: with any number of critical messages outstanding,
// SOS and LEAVE are hit-testable and their callbacks fire.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart' as awareness_geo;
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/quick_message.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/domain/route_store.dart';
import 'package:ride_relay/features/map/ride_map.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/offline_tile_cache.dart';
import 'package:ride_relay/services/received_quick_message.dart';
import 'package:ride_relay/services/route_importer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  RideQuickMessageAlert interrupting(String eventId) => RideQuickMessageAlert(
    message: ReceivedQuickMessage(
      eventId: eventId,
      senderRiderId: 'kate',
      senderDisplayName: 'Kate',
      label: QuickMessage.emergencyStop.label,
      priority: QuickMessage.emergencyStop.priority,
      raisedAt: DateTime.utc(2026, 7, 27, 18),
      raisedFromLocalRider: false,
      message: QuickMessage.emergencyStop,
      raisedAtPosition: const awareness_geo.GeoPoint(
        latitude: 51.46,
        longitude: -2.5,
      ),
    ),
  );

  Future<_Presses> pumpWithInterrupts(
    WidgetTester tester,
    int count, {
    Size size = const Size(390, 844),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final directory = Directory.systemTemp.createTempSync('interrupt-safety');
    addTearDown(() => directory.deleteSync(recursive: true));
    final cache = OfflineTileCache(
      rootDirectory: directory,
      configuration: const BasemapConfiguration(),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );

    final presses = _Presses();
    final alerts = ValueNotifier<List<RideQuickMessageAlert>>([
      for (var index = 0; index < count; index += 1) interrupting('sos-$index'),
    ]);
    addTearDown(alerts.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: RideMapScreen(
          routeStore: InMemoryRouteStore(_route),
          routeImporter: RouteImporter(source: const _NoFileSource()),
          offlineTileCache: cache,
          quickMessageAlerts: alerts,
          onAcknowledgeQuickMessage: (_) async {},
          onEmergencyAlert: () async => presses.sos += 1,
          onLeaveRide: () async => presses.leave += 1,
          onReportHazard: (_) async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    return presses;
  }

  testWidgets('the interrupt is up, and it is up', (tester) async {
    await pumpWithInterrupts(tester, 1);

    expect(
      find.byKey(const Key('quick-message-interrupt')),
      findsOneWidget,
      reason: 'the rest of this file is meaningless if it never appeared',
    );
  });

  testWidgets('Leave fires on the first press while interrupting', (
    tester,
  ) async {
    final presses = await pumpWithInterrupts(tester, 1);

    await tester.tap(find.byKey(const Key('leave-ride-button')));
    await tester.pumpAndSettle();

    expect(
      presses.leave,
      1,
      reason: 'Leave must not need the alert cleared first',
    );
  });

  testWidgets('SOS fires on the first press while interrupting', (
    tester,
  ) async {
    final presses = await pumpWithInterrupts(tester, 1);

    await tester.tap(find.byKey(const Key('emergency-alert-button')));
    await tester.pumpAndSettle();

    expect(
      presses.sos,
      1,
      reason:
          'a rider needing help must not have to dismiss somebody else\'s '
          'alert to ask for it',
    );
  });

  testWidgets('several outstanding criticals still leave both reachable', (
    tester,
  ) async {
    // The reported case: a queue of messages, one tap each before the old
    // overlay let go of the screen.
    await pumpWithInterrupts(tester, 4);

    final overlay = tester.getRect(
      find.byKey(const Key('quick-message-interrupt')),
    );
    for (final key in const [
      Key('emergency-alert-button'),
      Key('leave-ride-button'),
    ]) {
      final control = tester.getRect(find.byKey(key));
      expect(
        control.top,
        greaterThanOrEqualTo(overlay.bottom - 0.5),
        reason:
            '$key must sit below the interrupt, not behind it, however many '
            'messages are outstanding',
      );
    }
  });

  testWidgets('the interrupt still covers the map above the controls', (
    tester,
  ) async {
    await pumpWithInterrupts(tester, 1);

    final overlay = tester.getRect(
      find.byKey(const Key('quick-message-interrupt')),
    );
    // It has to remain unmissable: reserving the action band must not turn it
    // into a strip. The top offset is the status bar inset the overlay's own
    // SafeArea leaves.
    expect(overlay.top, lessThan(80));
    expect(
      overlay.height,
      greaterThan(844 * 0.5),
      reason:
          'an alert a rider can overlook is the fault this replaced. The band '
          'reserved is the whole bottom chrome rail, deliberately - it is the '
          'measurement that exists, and reserving slightly too much is the safe '
          'direction when the alternative is covering SOS',
    );
  });

  testWidgets('landscape keeps Leave pressable too', (tester) async {
    // Landscape lays the actions out differently, so the assertion is the one
    // that matters rather than a geometric guess: it still fires. Before this
    // change it fired zero times here.
    //
    // SOS is not pressed in landscape: doing so opens the emergency actions
    // sheet, which overflows a 390 px-tall viewport by 58 px on its own. That is
    // a real defect and predates this change - raised separately rather than
    // worked around here.
    final presses = await pumpWithInterrupts(
      tester,
      2,
      size: const Size(844, 390),
    );

    await tester.tap(find.byKey(const Key('leave-ride-button')));
    await tester.pumpAndSettle();

    expect(presses.leave, 1);
  });
}

class _Presses {
  int sos = 0;
  int leave = 0;
}

final _route = ImportedRoute(
  id: 'interrupt-safety',
  name: 'Interrupt safety route',
  importedAt: DateTime.utc(2026, 7, 27),
  sourceFileName: 'interrupt-safety.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 51.46, longitude: -2.5),
        GeoPoint(latitude: 51.47, longitude: -2.49),
      ],
    ),
  ],
  waypoints: const [],
);

class _NoFileSource implements GpxImportSource {
  const _NoFileSource();

  @override
  Future<PickedGpxFile?> pickGpxFile() async => null;
}

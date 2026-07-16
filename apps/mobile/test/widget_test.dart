import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/app/ride_relay_app.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/services/nearby_bridge.dart';

void main() {
  testWidgets('home screen exposes the two ride entry points', (tester) async {
    final controller = await _controller();
    await tester.pumpWidget(
      RideRelayApp(controller: controller, enableNativeServices: false),
    );

    expect(find.text('Create a ride'), findsOneWidget);
    expect(find.text('Join with a code'), findsOneWidget);
    expect(find.textContaining('still connected'), findsOneWidget);

    controller.dispose();
  });

  testWidgets('active ride shows coordination controls', (tester) async {
    final controller = await _controller();
    await controller.createRide('Oliver');
    await tester.pumpWidget(
      RideRelayApp(controller: controller, enableNativeServices: false),
    );
    await tester.pumpAndSettle();

    expect(find.text('Oliver'), findsOneWidget);
    expect(find.text('QUICK MESSAGES'), findsOneWidget);
    expect(find.text('Marker mode'), findsOneWidget);
    expect(find.text('Map'), findsOneWidget);
    expect(find.text('Awareness'), findsOneWidget);

    await tester.tap(find.text('Awareness'));
    await tester.pumpAndSettle();

    expect(find.text('Ride awareness'), findsOneWidget);
    expect(find.text('ACTIVE HAZARDS'), findsOneWidget);

    controller.dispose();
  });
}

Future<RideController> _controller() async {
  final controller = RideController(
    InMemoryEventStore(),
    InMemorySessionStore(),
    const _FakeNearbyBridge(),
  );
  await controller.initialize();
  return controller;
}

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async => const NearbyCapabilities(
    platform: 'test',
    nativeBridgeReady: true,
    nearbyApiLinked: false,
    status: 'phase0',
  );
}

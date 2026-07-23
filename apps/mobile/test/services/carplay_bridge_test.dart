import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/carplay_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/carplay');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'publishes a Driving Task snapshot no more than every ten seconds',
    () async {
      final calls = <MethodCall>[];
      var now = DateTime.utc(2026, 7, 23, 12);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final bridge = CarPlayBridge(channel: channel, clock: () => now);
      addTearDown(bridge.dispose);

      Future<void> publish() => bridge.publish(
        session: null,
        riderLocations: const [],
        routeAlerts: const [],
        activeHazards: const [],
      );

      await publish();
      now = now.add(const Duration(seconds: 9));
      await publish();
      now = now.add(const Duration(seconds: 1));
      await publish();

      expect(calls, hasLength(2));
      expect(calls.every((call) => call.method == 'updateSnapshot'), isTrue);
      expect(calls.first.arguments, {'riders': <Object?>[], 'alert': null});
    },
  );
}

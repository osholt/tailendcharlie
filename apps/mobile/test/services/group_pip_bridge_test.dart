import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/group_pip_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('test/group-pip');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('enters, publishes bounded snapshots, and closes explicitly', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'enter' || 'updateSnapshot' => true,
        _ => null,
      };
    });
    final bridge = GroupPipBridge(channel: channel);
    addTearDown(bridge.dispose);
    final route = [
      for (var index = 0; index < 1200; index += 1)
        GeoPoint(latitude: 51 + index / 100000, longitude: -3),
    ];
    final snapshot = GroupPipSnapshot(
      routePaths: [route],
      markers: [
        for (var index = 0; index < 120; index += 1)
          GroupPipMarker(
            point: GeoPoint(latitude: 51, longitude: -3 + index / 100000),
            label: 'Rider $index',
            colourArgb: 0xFF3478F6,
            kind: GroupPipMarkerKind.rider,
            isLocal: index == 0,
          ),
      ],
      status: 'TEC 1.2 mi behind',
      alert: true,
    );

    expect(await bridge.enter(snapshot), isTrue);
    await bridge.publish(snapshot);
    await bridge.close();

    expect(calls.map((call) => call.method), [
      'enter',
      'updateSnapshot',
      'close',
    ]);
    final payload = Map<String, Object?>.from(calls.first.arguments as Map);
    final routePaths = payload['routePaths'] as List<Object?>;
    expect(routePaths, hasLength(1));
    expect(routePaths.single as List<Object?>, hasLength(401));
    expect(payload['markers'] as List<Object?>, hasLength(100));
    expect(payload['status'], 'TEC 1.2 mi behind');
    expect(payload['alert'], isTrue);
    expect(bridge.active, isFalse);
  });

  test('does not publish until the user has entered PiP', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });
    final bridge = GroupPipBridge(channel: channel);
    addTearDown(bridge.dispose);

    await bridge.publish(const GroupPipSnapshot(routePaths: [], markers: []));

    expect(calls, isEmpty);
  });
}

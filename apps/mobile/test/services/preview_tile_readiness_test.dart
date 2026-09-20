import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/preview_tile_readiness.dart';

void main() {
  testWidgets('camera ready alone never permits a cached blank map', (
    tester,
  ) async {
    var captures = 0;
    final readiness = PreviewTileReadiness(onReady: () => captures++);
    addTearDown(readiness.dispose);
    readiness.cameraReady();
    await tester.pump(const Duration(seconds: 2));
    expect(captures, 0);
    final pending = Completer<int>();
    final load = readiness.track(() => pending.future);
    await tester.pump(const Duration(seconds: 2));
    expect(captures, 0);
    pending.complete(1);
    await load;
    await tester.pump(const Duration(milliseconds: 800));
    expect(captures, 1);
  });
  testWidgets('one failed tile prevents caching a partial preview', (
    tester,
  ) async {
    var captures = 0;
    final readiness = PreviewTileReadiness(onReady: () => captures++);
    addTearDown(readiness.dispose);
    readiness.cameraReady();
    await readiness.track(() async => 1);
    await expectLater(
      readiness.track(() async => throw StateError('offline')),
      throwsStateError,
    );
    await tester.pump(const Duration(seconds: 2));
    expect(captures, 0);
  });
  testWidgets('late tile and sprite requests postpone the quiet interval', (
    tester,
  ) async {
    var captures = 0;
    final readiness = PreviewTileReadiness(onReady: () => captures++);
    readiness.cameraReady();
    await readiness.track(() async => 1);
    await tester.pump(const Duration(milliseconds: 700));
    final sprite = Completer<int>();
    final load = readiness.track(() => sprite.future, tile: false);
    await tester.pump(const Duration(seconds: 2));
    expect(captures, 0);
    sprite.complete(1);
    await load;
    readiness.dispose();
    await tester.pump(const Duration(seconds: 2));
    expect(captures, 0);
  });
}

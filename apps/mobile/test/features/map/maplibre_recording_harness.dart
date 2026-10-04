import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;

/// Mounts [app] on the MapLibre render path with the platform channel recording
/// every call, completes the style set-up a real platform view would trigger,
/// and returns what the plugin was asked to do, in order.
///
/// Android draws the live ride map through MapLibre, and a widget test cannot
/// create the native view. What the Dart side tells the plugin - which layers it
/// adds and in what order, which images it registers - is the part that decides
/// what a rider sees, so that is what these tests read.
///
/// [until] says when the set-up has finished; by default that is the last layer
/// the ride map adds.
Future<List<MethodCall>> recordMapLibreStyleSetUp(
  WidgetTester tester,
  Widget app, {
  bool Function(List<MethodCall> calls)? until,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final calls = <MethodCall>[];
  const channel = MethodChannel('plugins.flutter.io/maplibre_gl_0');
  const views = MethodChannel('flutter/platform_views');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final original = ml.MapLibrePlatform.createInstance;
  messenger.setMockMethodCallHandler(views, (call) async {
    if (call.method == 'create') return 0;
    if (call.method == 'resize') {
      final args = call.arguments as Map;
      return {'width': args['width'], 'height': args['height']};
    }
    return null;
  });
  messenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    return null;
  });
  ml.MapLibrePlatform.createInstance = () {
    final platform = ml.MapLibreMethodChannel();
    unawaited(platform.initPlatform(0));
    return platform;
  };
  addTearDown(() {
    ml.MapLibrePlatform.createInstance = original;
    messenger.setMockMethodCallHandler(views, null);
    // The suite's own handler is installed once for the whole file, so put it
    // back rather than leaving the channel unanswered.
    messenger.setMockMethodCallHandler(channel, (_) async => null);
  });

  await tester.pumpWidget(app);
  // The first frame is the loading state; the map follows once the stored route
  // has been read.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  final map = tester.widget<ml.MapLibreMap>(find.byType(ml.MapLibreMap));
  final platform = ml.MapLibreMethodChannel();
  await platform.initPlatform(0);
  final controller = ml.MapLibreMapController(
    maplibrePlatform: platform,
    annotationOrder: const [],
    annotationConsumeTapEvents: const [],
  );
  map.onMapCreated!(controller);
  map.onStyleLoadedCallback!();

  final finished =
      until ??
      (List<MethodCall> recorded) => recorded.any(
        (call) =>
            call.method == 'symbolLayer#add' &&
            (call.arguments as Map)['layerId'] == 'ride-relay-hazard-symbols',
      );
  // Rasterising the marker images runs on the engine, outside the fake clock,
  // and what it was awaited by only resumes when the fake zone is pumped. So
  // alternate: let the engine work, then pump.
  final deadline = DateTime.now().add(timeout);
  while (!finished(calls) && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(
    finished(calls),
    isTrue,
    reason:
        'the MapLibre style set-up did not finish; calls: '
        '${calls.map((call) => call.method).toList()}',
  );
  return List.unmodifiable(calls);
}

extension RecordedMapLibreCalls on List<MethodCall> {
  /// The ids of every layer of [method] (`lineLayer#add`, `symbolLayer#add`,
  /// `circleLayer#add`...), in the order they were added.
  List<String> layerIds(String method) => [
    for (final call in this)
      if (call.method == method) (call.arguments as Map)['layerId'] as String,
  ];

  /// Every layer of any kind, in the order it was added - which is the order
  /// MapLibre paints them, bottom first.
  List<String> get allLayerIds => [
    for (final call in this)
      if (call.method.endsWith('Layer#add'))
        (call.arguments as Map)['layerId'] as String,
  ];

  /// The arguments of the `*Layer#add` call for [layerId].
  Map<Object?, Object?> layer(String layerId) => [
    for (final call in this)
      if (call.method.endsWith('Layer#add') &&
          (call.arguments as Map)['layerId'] == layerId)
        call.arguments as Map<Object?, Object?>,
  ].single;

  /// The `style#addImage` calls, by image name.
  Map<String, Map<Object?, Object?>> get images => {
    for (final call in this)
      if (call.method == 'style#addImage')
        (call.arguments as Map)['name'] as String:
            call.arguments as Map<Object?, Object?>,
  };
}

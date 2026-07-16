import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/data/json_file_route_store.dart';
import 'package:ride_relay/domain/imported_route.dart';

void main() {
  test('persists, replaces, and clears the active route', () async {
    final directory = await Directory.systemTemp.createTemp('route-store-test');
    addTearDown(() => directory.delete(recursive: true));
    final store = JsonFileRouteStore(File('${directory.path}/active.json'));
    final first = _route('first', 'First route');
    final second = _route('second', 'Second route');

    expect(await store.loadActiveRoute(), isNull);
    await store.saveActiveRoute(first);
    expect((await store.loadActiveRoute())?.name, 'First route');
    await store.saveActiveRoute(second);
    expect((await store.loadActiveRoute())?.id, 'second');
    await store.clearActiveRoute();
    expect(await store.loadActiveRoute(), isNull);
  });
}

ImportedRoute _route(String id, String name) => ImportedRoute(
  id: id,
  name: name,
  importedAt: DateTime.utc(2026),
  sourceFileName: '$id.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [GeoPoint(latitude: 53, longitude: -1)],
    ),
  ],
  waypoints: const [],
);

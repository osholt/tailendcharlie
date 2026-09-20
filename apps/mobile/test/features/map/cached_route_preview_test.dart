import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/features/map/cached_route_preview.dart';
import 'package:ride_relay/features/map/flutter_vector_route_preview.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/route_preview_cache.dart';

void main() {
  testWidgets('a saved thumbnail is shown without mounting a tile renderer', (
    tester,
  ) async {
    final cache = MemoryPreviewCache();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 52,
            height: 52,
            child: CachedRoutePreview(
              cache: cache,
              paths: const [
                [
                  GeoPoint(latitude: 50, longitude: 1),
                  GeoPoint(latitude: 51, longitude: 2),
                ],
              ],
              configuration: const BasemapConfiguration(
                styleUrl: 'https://offline.invalid/style.json',
                attribution: 'Map attribution',
              ),
              colour: Colors.teal,
              fallback: const Text('Route outline'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(cache.reads, 1);
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(FlutterVectorRoutePreview), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}

class MemoryPreviewCache extends RoutePreviewCache {
  MemoryPreviewCache() : super(Directory.systemTemp);
  int reads = 0;
  @override
  Future<Uint8List?> read(String key) async {
    reads++;
    return base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
  }
}

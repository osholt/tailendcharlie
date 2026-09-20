import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/route_preview_cache.dart';

void main() {
  const paths = [
    [
      GeoPoint(latitude: 50, longitude: 1),
      GeoPoint(latitude: 51, longitude: 2),
    ],
  ];
  const configuration = BasemapConfiguration(
    styleUrl: 'https://tiles.test/style.json',
    attribution: 'Test map',
  );
  String key({
    int colour = 1,
    int width = 52,
    List<List<GeoPoint>> geometry = paths,
    BasemapConfiguration style = configuration,
  }) => RoutePreviewCache.key(
    paths: geometry,
    configuration: style,
    colourArgb: colour,
    width: width,
    height: 52,
    pixelRatio: 2,
  );
  test('cache identity invalidates geometry, style, colour and size edits', () {
    final keys = {
      key(),
      key(colour: 2),
      key(width: 53),
      key(geometry: [paths.single.reversed.toList()]),
      key(
        style: const BasemapConfiguration(
          styleUrl: 'https://tiles.test/night.json',
          attribution: 'Test map',
        ),
      ),
    };
    expect(keys, hasLength(5));
    expect(key(), key());
  });
  test('preview survives a cache reopen and disk use is bounded', () async {
    final directory = await Directory.systemTemp.createTemp(
      'tec-preview-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final bytes = Uint8List.fromList([
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      ...List.filled(40, 0),
    ]);
    final cache = RoutePreviewCache(directory, maximumBytes: 80);
    await cache.save(key(), bytes);
    expect(await RoutePreviewCache(directory).read(key()), bytes);
    await File(
      '${directory.path}/${key()}.png',
    ).setLastModified(DateTime.utc(2020));
    await cache.save(key(colour: 2), bytes);
    expect(await cache.read(key()), isNull);
    expect(await cache.read(key(colour: 2)), bytes);
    final files = directory.listSync().whereType<File>();
    expect(
      files.fold(0, (sum, file) => sum + file.lengthSync()),
      lessThanOrEqualTo(80),
    );
  });
  test(
    'corrupt files and arbitrary paths never become usable previews',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tec-preview-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final cache = RoutePreviewCache(directory);
      await File('${directory.path}/${key()}.png').writeAsString('broken');
      expect(await cache.read(key()), isNull);
      await cache.save(key(), Uint8List.fromList([1, 2, 3]));
      expect(await cache.read(key()), isNull);
      await expectLater(cache.read('../secret'), throwsArgumentError);
    },
  );
}

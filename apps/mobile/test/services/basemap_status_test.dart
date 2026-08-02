import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/services/basemap_status.dart';
import 'package:ride_relay/services/map_style_repository.dart';

/// The three faults behind #281 all drew the same picture — a dot and a trail
/// on a dark background — so the only thing that separates them is what the app
/// says. These hold each one to its own words.
void main() {
  group('resolveBasemapStatus', () {
    BasemapStatus status({
      MapStyleOutcome outcome = MapStyleOutcome.live,
      bool viewLoadedStyle = true,
      bool viewLoadTimedOut = false,
      bool? tilesReachable,
    }) => resolveBasemapStatus(
      styleOutcome: outcome,
      viewLoadedStyle: viewLoadedStyle,
      viewLoadTimedOut: viewLoadTimedOut,
      tilesReachable: tilesReachable,
    );

    test('a working map reports no fault, so an empty area stays empty', () {
      // The whole point of the badge is that its absence means something. A map
      // with nothing on it and no badge is countryside, not a failure.
      expect(status(tilesReachable: true), BasemapStatus.drawing);
      expect(status().isFault, isFalse);
      expect(status().badgeLabel, isEmpty);
    });

    test('a style that could not be fetched is named as that', () {
      expect(
        status(outcome: MapStyleOutcome.unavailable),
        BasemapStatus.styleUnavailable,
      );
    });

    test('an unconfigured build is route-only, not a failure', () {
      expect(
        status(outcome: MapStyleOutcome.unconfigured),
        BasemapStatus.routeOnly,
      );
    });

    test('a cached style is a real basemap and reports no fault', () {
      // A stale cache still has roads in it. Reporting it as a failure would
      // put a warning on a perfectly usable map.
      expect(status(outcome: MapStyleOutcome.cached), BasemapStatus.drawing);
    });

    test('tiles that do not answer are a different fault from the style', () {
      expect(status(tilesReachable: false), BasemapStatus.tilesUnavailable);
      expect(
        BasemapStatus.tilesUnavailable.badgeLabel,
        isNot(BasemapStatus.styleUnavailable.badgeLabel),
      );
    });

    test('a probe with nothing to ask never invents a fault', () {
      expect(status(tilesReachable: null), BasemapStatus.drawing);
    });

    test('a map still starting up says nothing', () {
      // Warning about a map that is one second from appearing would be the
      // same fault as saying nothing at all, in the other direction.
      expect(
        status(viewLoadedStyle: false, viewLoadTimedOut: false),
        BasemapStatus.drawing,
      );
    });

    test(
      'a view that never loaded the style is reported once it times out',
      () {
        expect(
          status(viewLoadedStyle: false, viewLoadTimedOut: true),
          BasemapStatus.viewNeverLoaded,
        );
      },
    );

    test('a style that never arrived outranks a view that never loaded', () {
      // The view had nothing to load, so blaming the view would send the next
      // investigation to the wrong place.
      expect(
        status(
          outcome: MapStyleOutcome.unavailable,
          viewLoadedStyle: false,
          viewLoadTimedOut: true,
        ),
        BasemapStatus.styleUnavailable,
      );
    });

    test('every fault has its own label and its own explanation', () {
      final faults = BasemapStatus.values.where((value) => value.isFault);
      expect(faults, hasLength(4));
      expect(
        faults.map((value) => value.badgeLabel).toSet(),
        hasLength(faults.length),
      );
      expect(
        faults.map((value) => value.explanation).toSet(),
        hasLength(faults.length),
      );
      for (final fault in faults) {
        expect(fault.badgeLabel, isNotEmpty);
        expect(fault.explanation, isNotEmpty);
      }
    });
  });

  group('BasemapTileProbe.endpointFor', () {
    String style(Map<String, Object?> sources) =>
        jsonEncode({'version': 8, 'sources': sources, 'layers': <Object>[]});

    test('prefers the TileJSON document a source names', () {
      expect(
        BasemapTileProbe.endpointFor(
          style({
            'planet': {
              'type': 'vector',
              'url': 'https://tiles.example.test/planet',
              'tiles': ['https://tiles.example.test/{z}/{x}/{y}.pbf'],
            },
          }),
        ),
        Uri.parse('https://tiles.example.test/planet'),
      );
    });

    test('falls back to the 0/0/0 tile, which every pyramid has', () {
      // Not a tile near the rider: the probe must not depend on where the ride
      // happens to be, or it would report a fault for a legitimately empty
      // corner of the world.
      expect(
        BasemapTileProbe.endpointFor(
          style({
            'planet': {
              'type': 'vector',
              'tiles': ['https://tiles.example.test/{z}/{x}/{y}.pbf'],
            },
          }),
        ),
        Uri.parse('https://tiles.example.test/0/0/0.pbf'),
      );
    });

    test('declines anything it cannot be sure about', () {
      // Each of these must produce no probe at all rather than a guess, because
      // a guess that fails becomes a warning on a working map.
      expect(BasemapTileProbe.endpointFor('not json'), isNull);
      expect(BasemapTileProbe.endpointFor(style({})), isNull);
      expect(
        BasemapTileProbe.endpointFor(MapStyleRepository.fallbackStyle),
        isNull,
      );
      expect(
        BasemapTileProbe.endpointFor(
          style({
            'planet': {
              'type': 'raster',
              'tiles': ['https://tiles.example.test/{quadkey}.png'],
            },
          }),
        ),
        isNull,
        reason: 'an unrecognised placeholder is left alone, not substituted',
      );
      expect(
        BasemapTileProbe.endpointFor(
          style({
            'planet': {
              'type': 'vector',
              'tiles': ['http://tiles.example.test/{z}/{x}/{y}.pbf'],
            },
          }),
        ),
        isNull,
        reason: 'the app is https-only everywhere else too',
      );
    });
  });

  group('BasemapTileProbe.reachable', () {
    const probe = BasemapTileProbe();
    final style = jsonEncode({
      'version': 8,
      'sources': {
        'planet': {
          'type': 'vector',
          'url': 'https://tiles.example.test/planet',
        },
      },
      'layers': <Object>[],
    });

    test('true when the endpoint answers', () async {
      final client = MockClient((_) async => http.Response('{}', 200));
      expect(await probe.reachable(style, client: client), isTrue);
    });

    test('false when the endpoint is not there', () async {
      final client = MockClient((_) async => http.Response('nope', 404));
      expect(await probe.reachable(style, client: client), isFalse);
    });

    test('false when the request throws', () async {
      final client = MockClient((_) async => throw Exception('offline'));
      expect(await probe.reachable(style, client: client), isFalse);
    });

    test('null, not false, when there is nothing to ask for', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      });

      expect(
        await probe.reachable(MapStyleRepository.fallbackStyle, client: client),
        isNull,
      );
      expect(requests, 0, reason: 'no endpoint means no request at all');
    });

    test('asks for the endpoint once, and only that one', () async {
      final asked = <Uri>[];
      final client = MockClient((request) async {
        asked.add(request.url);
        return http.Response('{}', 200);
      });

      await probe.reachable(style, client: client);

      expect(asked, [Uri.parse('https://tiles.example.test/planet')]);
    });
  });
}

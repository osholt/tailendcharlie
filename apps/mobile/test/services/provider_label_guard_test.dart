// The Flutter vector renderer's expression parser is not part of its public
// API, and the one test here that proves the portable label parses and
// evaluates there has to reach it.
// ignore_for_file: implementation_imports

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/services/basemap_configuration.dart';
import 'package:ride_relay/services/flutter_vector_resource_cache.dart';
import 'package:ride_relay/services/flutter_vector_style.dart';
import 'package:ride_relay/services/map_style_repository.dart';
import 'package:ride_relay/services/provider_label_guard.dart';
import 'package:vector_tile_renderer/src/themes/expression/expression.dart'
    as renderer;
import 'package:vector_tile_renderer/vector_tile_renderer.dart'
    show Logger, TileFeatureType;

/// Cover for #860: a charging station at a motorway service area was labelled
/// "Gridserve" followed by a UUID.
///
/// Nothing in this app built that label. The tile generator behind OpenFreeMap
/// gives an unnamed charging station or parcel locker a name made of its brand
/// and its `ref`, and the provider's style draws it (see [ProviderLabelGuard]).
/// These tests hold the guard to the names the provider actually publishes
/// (`test/fixtures/openfreemap_poi_names.json`, recorded from real tiles) and to
/// the provider's real POI layers (`openfreemap_liberty_poi.json`).
///
/// An expression cannot be run by MapLibre from here. The native semantics were
/// checked in MapLibre GL JS and on an iOS and an Android build, which `docs/
/// maps-and-gpx.md` records; what these tests prove is the document each
/// renderer is handed, and what it evaluates to wherever a Dart evaluator
/// exists.

/// Mirrors the settings of a rider on the Original daytime map, the only style
/// that draws provider POIs.
final _original = const BasemapConfiguration(
  styleUrl: BasemapConfiguration.defaultLightStyleUrl,
  darkStyleUrl: BasemapConfiguration.defaultDarkStyleUrl,
  attribution: '© OpenStreetMap contributors',
  cacheNamespace: BasemapConfiguration.defaultCacheNamespace,
  persistentCachingAllowed: true,
).forBrightness(dark: false, restrainedLightStyle: false);

const _poiLayers = ['poi_r20', 'poi_r7', 'poi_r1', 'poi_transit'];

final _uuid = RegExp(
  r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
);

/// What a rider would call an identifier rather than a name: a UUID, a number
/// of five digits or more, or a single word that mixes letters and digits and
/// runs to six characters or more (`UKLON00047`, `FC18642`, `GB*BPL*E000199`).
bool looksLikeIdentifier(String label) {
  if (_uuid.hasMatch(label)) return true;
  for (final token in label.split(RegExp(r'\s+'))) {
    if (RegExp(r'\d{5,}').hasMatch(token)) return true;
    if (token.length >= 6 &&
        token.contains(RegExp(r'\d')) &&
        token.contains(RegExp(r'[A-Za-z]'))) {
      return true;
    }
  }
  return false;
}

/// One POI as the tile publishes it: every name field carries the same text.
Map<String, Object?> feature(String klass, String subclass, String? name) => {
  'class': klass,
  'subclass': subclass,
  'name': ?name,
  'name_en': ?name,
  'name:latin': ?name,
};

List<Map<String, Object?>> _recordedPois() =>
    ((jsonDecode(
                  File(
                    'test/fixtures/openfreemap_poi_names.json',
                  ).readAsStringSync(),
                )
                as Map)['pois']
            as List)
        .cast<Map<String, dynamic>>()
        .map(
          (poi) => feature(
            poi['class'] as String,
            poi['subclass'] as String,
            poi['name'] as String,
          ),
        )
        .toList();

Map<String, dynamic> _provider() =>
    jsonDecode(
          File('test/fixtures/openfreemap_liberty_poi.json').readAsStringSync(),
        )
        as Map<String, dynamic>;

Map<String, dynamic> _layer(Map<String, dynamic> style, String id) =>
    (style['layers'] as List).cast<Map<String, dynamic>>().singleWhere(
      (layer) => layer['id'] == id,
    );

Object? _textField(Map<String, dynamic> style, String id) =>
    (_layer(style, id)['layout'] as Map)['text-field'];

/// Evaluates the MapLibre expression forms the provider's label and the guard
/// use, for one feature. Semantics follow the style specification: `in` looks
/// for a substring, `to-string` turns null into the empty string, and `coalesce`
/// takes the first value that is not null.
Object? evaluate(
  Object? expression,
  Map<String, Object?> properties, [
  Map<String, Object?> variables = const {},
]) {
  if (expression is! List) return expression;
  Object? eval(Object? e) => evaluate(e, properties, variables);
  final operator = expression.first as String;
  switch (operator) {
    case 'let':
      final bound = {
        ...variables,
        expression[1] as String: eval(expression[2]),
      };
      return evaluate(expression.last, properties, bound);
    case 'var':
      return variables[expression[1]];
    case 'get':
      return properties[expression[1]];
    case 'has':
      return properties[expression[1]] != null;
    case 'to-string':
      final value = eval(expression[1]);
      return value == null ? '' : '$value';
    case 'concat':
      return expression.skip(1).map((e) => '${eval(e) ?? ''}').join();
    case 'coalesce':
      for (final e in expression.skip(1)) {
        final value = eval(e);
        if (value != null) return value;
      }
      return null;
    case 'in':
      return (eval(expression[2]) as String).contains(
        eval(expression[1])! as String,
      );
    case 'all':
      return expression.skip(1).every((e) => eval(e) == true);
    case 'any':
      return expression.skip(1).any((e) => eval(e) == true);
    case 'case':
      for (var i = 1; i + 1 < expression.length; i += 2) {
        if (eval(expression[i]) == true) return eval(expression[i + 1]);
      }
      return eval(expression.last);
    case 'match':
      final input = eval(expression[1]);
      for (var i = 2; i + 1 < expression.length; i += 2) {
        final labels = expression[i] is List
            ? expression[i] as List
            : [expression[i]];
        if (labels.contains(input)) return eval(expression[i + 1]);
      }
      return eval(expression.last);
  }
  throw UnsupportedError('Expression $operator is not modelled here.');
}

/// The label MapLibre draws for [properties] on [layer] of [style].
String? labelOf(
  Map<String, dynamic> style,
  Map<String, Object?> properties, {
  String layer = 'poi_r1',
}) {
  final value = evaluate(_textField(style, layer), properties);
  return value == null ? null : '$value';
}

/// The label the Flutter vector renderer draws, through its own parser.
String? rendererLabelOf(
  Map<String, dynamic> style,
  Map<String, Object?> properties,
) {
  final expression = renderer.ExpressionParser(
    const Logger.noop(),
  ).parse(_textField(style, 'poi_r1'));
  expect(
    expression,
    isNot(isA<renderer.UnsupportedExpression>()),
    reason: 'the Flutter renderer cannot read this label',
  );
  final value = expression.evaluate(
    renderer.EvaluationContext(
      () => properties,
      TileFeatureType.point,
      const Logger.noop(),
      zoom: 17,
      zoomScaleFactor: 1,
      hasImage: (_) => false,
    ),
  );
  return value == null ? null : '$value';
}

Map<String, dynamic> _guarded({bool portable = false}) {
  final style = _provider();
  ProviderLabelGuard.apply(style, portable: portable);
  return style;
}

bool _affected(Map<String, Object?> poi) =>
    ProviderLabelGuard.genericTypes.containsKey(poi['subclass']);

String _generic(Map<String, Object?> poi) =>
    ProviderLabelGuard.genericTypes[poi['subclass']]!;

void main() {
  final pois = _recordedPois();

  test('the recorded provider names include the one in the field report', () {
    // The fixture is only worth having if it holds the label that started this.
    final names = pois.map((poi) => poi['name']).toSet();

    expect(names, contains('Gridserve 09981d11-e3db-479d-82cb-088d4dc046ba'));
    expect(pois.length, greaterThanOrEqualTo(30));
  });

  group('the provider draws the identifier today', () {
    test('the unguarded provider label is the name, UUID and all', () {
      final style = _provider();
      final label = labelOf(
        style,
        feature(
          'fuel',
          'charging_station',
          'Gridserve 09981d11-e3db-479d-82cb-088d4dc046ba',
        ),
      );

      expect(label, 'Gridserve 09981d11-e3db-479d-82cb-088d4dc046ba');
      expect(looksLikeIdentifier(label!), isTrue);
    });

    test('and the detector sees an identifier in every assembled name', () {
      // A guard tested against a detector that finds nothing proves nothing.
      var identifiers = 0;
      for (final poi in pois.where(_affected)) {
        final name = poi['name']! as String;
        if (!name.contains(RegExp(r'\d'))) continue;
        if (name == '42-14 Lancaster Grove') continue; // an address, not a ref
        identifiers++;
        expect(looksLikeIdentifier(name), isTrue, reason: name);
      }
      expect(identifiers, greaterThanOrEqualTo(15));
    });
  });

  group('no label the guard lets through is an identifier (#860)', () {
    for (final portable in [false, true]) {
      final variant = portable ? 'portable' : 'native';

      test('$variant: the field report label is the generic type', () {
        final style = _guarded(portable: portable);

        expect(
          labelOf(
            style,
            feature(
              'fuel',
              'charging_station',
              'Gridserve 09981d11-e3db-479d-82cb-088d4dc046ba',
            ),
          ),
          'EV charging',
        );
      });

      test('$variant: nothing recorded draws as an identifier', () {
        final style = _guarded(portable: portable);

        for (final poi in pois.where(_affected)) {
          final label = labelOf(style, poi);

          expect(label, isNotNull, reason: '${poi['name']}');
          expect(
            looksLikeIdentifier(label!),
            isFalse,
            reason: '${poi['name']} drew as "$label"',
          );
        }
      });

      test('$variant: every POI layer is guarded, not only the first', () {
        final style = _guarded(portable: portable);

        for (final id in _poiLayers) {
          expect(
            labelOf(
              style,
              feature('post', 'parcel_locker', 'InPost UKLON00047'),
              layer: id,
            ),
            'Parcel locker',
            reason: id,
          );
        }
      });
    }

    test('native: a name with no digit is a name, and is kept', () {
      final style = _guarded();

      for (final poi in pois.where(_affected)) {
        final name = poi['name']! as String;
        if (name.contains(RegExp(r'\d'))) {
          expect(labelOf(style, poi), _generic(poi), reason: name);
        } else {
          expect(labelOf(style, poi), name, reason: name);
        }
      }
      // A few the issue cares about, spelled out.
      expect(
        labelOf(style, feature('fuel', 'charging_station', 'BP Pulse')),
        'BP Pulse',
      );
      expect(
        labelOf(style, feature('post', 'parcel_locker', 'Amazon Locker')),
        'Amazon Locker',
      );
      expect(
        labelOf(style, feature('fuel', 'charging_station', 'bp pulse FC18642')),
        'EV charging',
      );
      expect(
        labelOf(style, feature('post', 'parcel_locker', 'InPost UKLON00047')),
        'Parcel locker',
      );
    });

    test('native: every digit counts, so a lone 9 or a lone 0 is caught', () {
      final style = _guarded();

      for (final digit in '0123456789'.split('')) {
        expect(
          labelOf(style, feature('fuel', 'charging_station', 'Brand $digit')),
          'EV charging',
          reason: 'a charging station named "Brand $digit"',
        );
      }
    });

    test('portable: the two kinds are labelled by what they are, always', () {
      final style = _guarded(portable: true);

      for (final poi in pois.where(_affected)) {
        expect(labelOf(style, poi), _generic(poi), reason: '${poi['name']}');
      }
    });

    test('everything else keeps the name the provider gave it', () {
      for (final portable in [false, true]) {
        final style = _guarded(portable: portable);

        for (final poi in pois.where((poi) => !_affected(poi))) {
          expect(
            labelOf(style, poi),
            poi['name'],
            reason: '${poi['name']} (${poi['subclass']}), portable: $portable',
          );
        }
      }
      // Names that look like identifiers to a detector but are what a mapper
      // wrote, on kinds the tile generator does not assemble a name for.
      final style = _guarded();
      expect(labelOf(style, feature('cafe', 'cafe', '1915')), '1915');
      expect(labelOf(style, feature('bar', 'bar', '108')), '108');
      expect(
        labelOf(style, feature('bus', 'bus_stop', 'Yorkshire 20220826')),
        'Yorkshire 20220826',
      );
    });

    test('a POI with no name stays unlabelled', () {
      for (final portable in [false, true]) {
        final style = _guarded(portable: portable);

        expect(
          labelOf(style, feature('parking', 'parking', null)),
          isNull,
          reason: 'portable: $portable',
        );
        expect(
          labelOf(style, feature('fuel', 'charging_station', null)),
          portable ? 'EV charging' : isNull,
          reason: 'portable: $portable',
        );
      }
    });

    test('the provider\'s non-Latin pairing is preserved', () {
      // `name:nonlatin` joins the Latin and the local name; the guard wraps that
      // expression rather than replacing it.
      final style = _guarded();
      final label = labelOf(style, {
        'class': 'cafe',
        'subclass': 'cafe',
        'name:latin': 'Cafe',
        'name:nonlatin': 'Kafe',
      });

      expect(label, 'Cafe\nKafe');
    });
  });

  group('only provider POI labels are touched', () {
    test(
      'road, place and airport labels are exactly as the provider wrote them',
      () {
        final before = _provider();
        final after = _guarded();

        for (final id in [
          'highway-name-major',
          'label_town',
          'airport',
          'background',
        ]) {
          expect(
            jsonEncode(_layer(after, id)),
            jsonEncode(_layer(before, id)),
            reason: id,
          );
        }
      },
    );

    test('a POI layer keeps everything but its label', () {
      final before = _provider();
      final after = _guarded();

      for (final id in _poiLayers) {
        final was = Map<String, dynamic>.from(_layer(before, id));
        final now = Map<String, dynamic>.from(_layer(after, id));
        final wasLayout = Map<String, dynamic>.from(
          was.remove('layout') as Map,
        );
        final nowLayout = Map<String, dynamic>.from(
          now.remove('layout') as Map,
        );
        final wasLabel = wasLayout.remove('text-field');
        nowLayout.remove('text-field');

        expect(jsonEncode(now), jsonEncode(was), reason: id);
        expect(jsonEncode(nowLayout), jsonEncode(wasLayout), reason: id);
        expect(ProviderLabelGuard.unwrap(_textField(after, id)), wasLabel);
      }
    });

    test(
      'guarding twice changes nothing, and either wrap can become the other',
      () {
        final once = _guarded();
        final twice = _guarded();
        ProviderLabelGuard.apply(twice);
        final switched = _guarded();
        ProviderLabelGuard.apply(switched, portable: true);
        ProviderLabelGuard.apply(switched);

        expect(jsonEncode(twice), jsonEncode(once));
        expect(jsonEncode(switched), jsonEncode(once));
        for (final id in _poiLayers) {
          expect(
            jsonEncode(ProviderLabelGuard.unwrap(_textField(once, id))),
            jsonEncode(_textField(_provider(), id)),
            reason: id,
          );
        }
      },
    );

    test('a style with no POI layers is left alone', () {
      final style = <String, dynamic>{
        'version': 8,
        'layers': [
          {'id': 'background', 'type': 'background'},
        ],
      };
      final before = jsonEncode(style);

      ProviderLabelGuard.apply(style);

      expect(jsonEncode(style), before);
    });
  });

  group('where the guard is applied', () {
    Map<String, dynamic> presented(BasemapConfiguration configuration) {
      final style = _provider();
      MapStyleRepository.applyPresentation(style, configuration);
      return style;
    }

    test('the Original daytime map is guarded', () {
      final style = presented(_original);

      expect(
        labelOf(
          style,
          feature(
            'fuel',
            'charging_station',
            'Gridserve 09981d11-e3db-479d-82cb-088d4dc046ba',
          ),
        ),
        'EV charging',
      );
    });

    test('the Restrained daytime map draws no provider POI at all', () {
      final style = presented(
        _original.forBrightness(dark: false, restrainedLightStyle: true),
      );
      final ids = (style['layers'] as List).map(
        (layer) => (layer as Map)['id'],
      );

      expect(ids, isNot(contains('poi_r1')));
      expect(ids, isNot(contains('poi_transit')));
    });

    test('a custom provider is never rewritten', () {
      final style = _provider();
      final before = jsonEncode(style);

      MapStyleRepository.applyPresentation(
        style,
        const BasemapConfiguration(styleUrl: 'https://custom.test/style'),
      );

      expect(jsonEncode(style), before);
    });

    test(
      'a cached style from the previous build is guarded on the way out',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'tec-label-guard',
        );
        addTearDown(() => directory.delete(recursive: true));
        final live = await MapStyleRepository(
          directory: directory,
          configuration: _original,
          client: MockClient(
            (_) async => http.Response(jsonEncode(_provider()), 200),
          ),
        ).resolve();
        final cachedFile = (await directory.list().toList())
            .whereType<File>()
            .single;
        // The previous build cached the provider's own label.
        final old = jsonDecode(live.style) as Map<String, dynamic>;
        for (final id in _poiLayers) {
          ((_layer(old, id)['layout']) as Map)['text-field'] = _textField(
            _provider(),
            id,
          );
        }
        await cachedFile.writeAsString(jsonEncode(old));

        final cached = await MapStyleRepository(
          directory: directory,
          configuration: _original,
          client: MockClient((_) async => throw StateError('offline')),
        ).resolve();
        final style = jsonDecode(cached.style) as Map<String, dynamic>;

        expect(cached.outcome, MapStyleOutcome.cached);
        expect(
          labelOf(
            style,
            feature(
              'fuel',
              'charging_station',
              'Gridserve 09981d11-e3db-479d-82cb-088d4dc046ba',
            ),
          ),
          'EV charging',
        );
      },
    );
  });

  group('the Flutter vector renderer (#860)', () {
    test(
      'reads the portable label and evaluates it as the native one does',
      () {
        final style = _guarded(portable: true);

        for (final poi in pois) {
          expect(
            rendererLabelOf(style, poi),
            labelOf(style, poi),
            reason: '${poi['name']} (${poi['subclass']})',
          );
        }
      },
    );

    test('the native label does not blank it, even if one gets that far', () {
      // Its `in` is a property filter, so it cannot see a digit and falls through
      // to the provider's own label. It must still parse and still label.
      final style = _guarded();

      for (final poi in pois) {
        expect(
          rendererLabelOf(style, poi),
          poi['name'],
          reason: '${poi['name']} (${poi['subclass']})',
        );
      }
    });

    test(
      'the vector style reader hands the renderer the portable label',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'tec-label-flutter',
        );
        addTearDown(() => directory.delete(recursive: true));
        final cache = FlutterVectorResourceCache(directory);
        final key = FlutterVectorResourceCache.key(
          'presentation-v3:${_original.styleUrl}:${_original.restrainedLightStyle}:${_original.dark}',
        );
        // What the native path caches: the document with the native label.
        final style = _provider();
        style['sources'] = {
          'openmaptiles': {'type': 'vector', 'url': 'https://maps.test/planet'},
        };
        ProviderLabelGuard.apply(style);
        await cache.write(
          key,
          Uint8List.fromList(utf8.encode(jsonEncode(style))),
        );
        await cache.write(
          FlutterVectorResourceCache.key('https://maps.test/planet'),
          Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'tiles': ['https://maps.test/{z}/{x}/{y}.pbf'],
                'minzoom': 0,
                'maxzoom': 14,
              }),
            ),
          ),
        );

        await readFlutterVectorStyle(
          _original,
          resourceCache: cache,
          clientFactory: () =>
              MockClient((_) async => throw const SocketException('offline')),
        );
        await cache.flushed;
        final stored =
            jsonDecode(utf8.decode((await cache.read(key))!))
                as Map<String, dynamic>;

        expect(
          labelOf(
            stored,
            feature(
              'fuel',
              'charging_station',
              'Gridserve 09981d11-e3db-479d-82cb-088d4dc046ba',
            ),
          ),
          'EV charging',
        );
        expect(
          labelOf(stored, feature('fuel', 'charging_station', 'BP Pulse')),
          'EV charging',
          reason: 'the Flutter renderer cannot tell a digit; it labels by type',
        );
      },
    );
  });
}

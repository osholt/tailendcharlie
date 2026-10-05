import 'dart:convert';

/// Keeps source identifiers out of the labels the basemap provider draws on its
/// points of interest (#860).
///
/// A field report from the 4 October group ride showed a charging station at a
/// motorway service area labelled with its operator's name and a UUID. Nothing
/// in this app built that label. OpenFreeMap's tiles are generated with the
/// OpenMapTiles profile for Planetiler, whose `Poi` layer gives an *unnamed*
/// charging station or parcel locker a name made of its brand (or operator) and
/// its `ref` (`BRAND_OPERATOR_REF_SUBCLASSES`). "Gridserve" and the Location ID
/// in Gridserve's open-data feed therefore arrive in the tile as one `name`, and
/// the provider's style draws whatever `name` says. The same rule produces
/// `bp pulse FC18642` and `InPost UKLON00047`.
///
/// Only the Original daytime map draws these labels: the Restrained repaint
/// removes every provider POI layer and the dark style has none.
///
/// The tile cannot say whether a name was written by a mapper or assembled from
/// a reference, so for the two kinds the generator assembles, a name that
/// contains a digit is treated as carrying a reference and is replaced by what
/// the thing is. A name with no digit in it is a brand or a place and is kept.
/// Every other kind of POI is untouched, so a café called "1915" still reads
/// "1915". The tile carries no separate brand, so the fallback after the name is
/// the generic type.
abstract final class ProviderLabelGuard {
  /// The kinds of POI the tile generator builds a name for, and the generic
  /// words used when that name carries a reference.
  static const genericTypes = <String, String>{
    'charging_station': 'EV charging',
    'parcel_locker': 'Parcel locker',
  };

  static const _variable = 'tecPoiLabel';
  static const _digits = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];

  /// Whether the POI is one of the kinds whose name may carry a reference.
  static final List<Object> _gate = [
    'match',
    ['get', 'subclass'],
    genericTypes.keys.toList(growable: false),
    true,
    false,
  ];

  /// What the POI is, in words.
  static final List<Object> _generic = [
    'match',
    ['get', 'subclass'],
    for (final entry in genericTypes.entries) ...[entry.key, entry.value],
    '',
  ];

  /// Wraps the label of every provider POI layer in [style].
  ///
  /// [portable] chooses an expression the Flutter vector renderer can evaluate.
  /// Its parser reads `in` as the legacy property filter rather than a string
  /// search and has no string operators, so it cannot look for a digit: it
  /// labels the two kinds by what they are, always. The native renderers get the
  /// version that keeps real names.
  ///
  /// Idempotent, and a document wrapped either way can be wrapped the other:
  /// the provider's own label is recovered before every wrap.
  static void apply(Map<String, dynamic> style, {bool portable = false}) {
    final layers = style['layers'];
    if (layers is! List) return;
    for (var i = 0; i < layers.length; i++) {
      final layer = layers[i];
      if (layer is! Map || layer['source-layer'] != 'poi') continue;
      final layout = layer['layout'];
      if (layout is! Map || !layout.containsKey('text-field')) continue;
      final original = unwrap(layout['text-field']);
      layers[i] = Map<String, dynamic>.from(layer)
        ..['layout'] = <String, dynamic>{
          ...layout.cast<String, dynamic>(),
          'text-field': portable ? _portable(original) : _native(original),
        };
    }
  }

  /// The provider's own label expression, whichever wrap [textField] carries.
  static Object? unwrap(Object? textField) {
    if (textField is! List || textField.length != 4) return textField;
    if (textField[0] == 'let' && textField[1] == _variable) {
      return textField[2];
    }
    if (textField[0] == 'case' && jsonEncode(textField[1]) == _gateJson) {
      return textField[3];
    }
    return textField;
  }

  static final String _gateJson = jsonEncode(_gate);

  static List<Object?> _native(Object? original) => [
    'let',
    _variable,
    original,
    [
      'case',
      [
        'all',
        _gate,
        [
          'any',
          for (final digit in _digits)
            [
              'in',
              digit,
              [
                'to-string',
                ['var', _variable],
              ],
            ],
        ],
      ],
      _generic,
      ['var', _variable],
    ],
  ];

  static List<Object?> _portable(Object? original) => [
    'case',
    _gate,
    _generic,
    original,
  ];
}

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'route_trail_style.dart';

/// Rider-selectable bike silhouettes, generated as flat single-colour art
/// (see assets/icons/motorcycles) so they can be tinted per role exactly like
/// the Icon widgets they replace.
enum MotorcycleIconStyle {
  adventureTourer,
  roadster,
  dualSport,
  sportNaked,
  cruiserClassic,
  standardTwin,
  cafeRacer,
  dirtBike,
  fullTourer,
  cruiserBagger,
  scrambler,
  sportTouring,
  scooter,
  sidecarRig,
  streetFighter,
}

extension MotorcycleIconStyleData on MotorcycleIconStyle {
  static const Map<MotorcycleIconStyle, String> _fileNames = {
    MotorcycleIconStyle.adventureTourer: '00_adventure_tourer',
    MotorcycleIconStyle.roadster: '01_roadster',
    MotorcycleIconStyle.dualSport: '02_dual_sport',
    MotorcycleIconStyle.sportNaked: '03_sport_naked',
    MotorcycleIconStyle.cruiserClassic: '04_cruiser_classic',
    MotorcycleIconStyle.standardTwin: '05_standard_twin',
    MotorcycleIconStyle.cafeRacer: '06_cafe_racer',
    MotorcycleIconStyle.dirtBike: '07_dirt_bike',
    MotorcycleIconStyle.fullTourer: '08_full_tourer',
    MotorcycleIconStyle.cruiserBagger: '09_cruiser_bagger',
    MotorcycleIconStyle.scrambler: '10_scrambler',
    MotorcycleIconStyle.sportTouring: '11_sport_touring',
    MotorcycleIconStyle.scooter: '12_scooter',
    MotorcycleIconStyle.sidecarRig: '13_sidecar_rig',
    MotorcycleIconStyle.streetFighter: '14_street_fighter',
  };

  String get assetPath => 'assets/icons/motorcycles/${_fileNames[this]}.png';

  String get label => switch (this) {
    MotorcycleIconStyle.adventureTourer => 'Adventure tourer',
    MotorcycleIconStyle.roadster => 'Roadster',
    MotorcycleIconStyle.dualSport => 'Dual sport',
    MotorcycleIconStyle.sportNaked => 'Sport naked',
    MotorcycleIconStyle.cruiserClassic => 'Classic cruiser',
    MotorcycleIconStyle.standardTwin => 'Standard twin',
    MotorcycleIconStyle.cafeRacer => 'Cafe racer',
    MotorcycleIconStyle.dirtBike => 'Dirt bike',
    MotorcycleIconStyle.fullTourer => 'Full tourer',
    MotorcycleIconStyle.cruiserBagger => 'Cruiser bagger',
    MotorcycleIconStyle.scrambler => 'Scrambler',
    MotorcycleIconStyle.sportTouring => 'Sport touring',
    MotorcycleIconStyle.scooter => 'Scooter',
    MotorcycleIconStyle.sidecarRig => 'Sidecar rig',
    MotorcycleIconStyle.streetFighter => 'Street fighter',
  };
}

/// Default style for sessions created before this feature existed, and the
/// fallback when a peer sends an unrecognised style name.
const motorcycleIconStyleDefault = MotorcycleIconStyle.adventureTourer;

MotorcycleIconStyle motorcycleIconStyleFromName(String? name) =>
    MotorcycleIconStyle.values.firstWhere(
      (style) => style.name == name,
      orElse: () => motorcycleIconStyleDefault,
    );

enum RiderSymbolKind { motorcycle, initials, emoji }

/// Ink choices for an initials marker. These stay separate from the rider's
/// badge colour because the same initials need to remain recognisable when two
/// riders choose similar identity colours.
enum RiderInitialsInk { dark, white, yellow, cyan, pink, purple }

extension RiderInitialsInkData on RiderInitialsInk {
  Color get color => switch (this) {
    RiderInitialsInk.dark => const Color(0xFF14202B),
    RiderInitialsInk.white => const Color(0xFFFFFFFF),
    RiderInitialsInk.yellow => const Color(0xFFFFD84D),
    RiderInitialsInk.cyan => const Color(0xFF3DDCFF),
    RiderInitialsInk.pink => const Color(0xFFFF76C8),
    RiderInitialsInk.purple => const Color(0xFF9B7BFF),
  };

  String get label => switch (this) {
    RiderInitialsInk.dark => 'Dark',
    RiderInitialsInk.white => 'White',
    RiderInitialsInk.yellow => 'Yellow',
    RiderInitialsInk.cyan => 'Cyan',
    RiderInitialsInk.pink => 'Pink',
    RiderInitialsInk.purple => 'Purple',
  };
}

const riderInitialsInkDefault = RiderInitialsInk.dark;

/// How a rider identifies themselves inside their coloured marker badge.
///
/// The wire representation deliberately reuses the existing
/// `motorcycleStyle` string. Old builds therefore see an unknown style and
/// safely fall back to the default bike, while new builds can show initials or
/// an emoji without requiring a relay protocol migration.
class RiderSymbol {
  const RiderSymbol.motorcycle()
    : kind = RiderSymbolKind.motorcycle,
      emoji = null,
      customInitials = null,
      initialsInk = riderInitialsInkDefault;

  const RiderSymbol.initials({
    this.customInitials,
    this.initialsInk = riderInitialsInkDefault,
  }) : kind = RiderSymbolKind.initials,
       emoji = null;

  const RiderSymbol.emoji(this.emoji)
    : kind = RiderSymbolKind.emoji,
      customInitials = null,
      initialsInk = riderInitialsInkDefault,
      assert(emoji != null && emoji != '');

  final RiderSymbolKind kind;
  final String? emoji;
  final String? customInitials;
  final RiderInitialsInk initialsInk;

  String get storageValue => switch (kind) {
    RiderSymbolKind.motorcycle => 'motorcycle',
    RiderSymbolKind.initials =>
      customInitials == null && initialsInk == riderInitialsInkDefault
          ? 'initials'
          : 'initials:v1:${_encodeInitials(customInitials)}:${initialsInk.name}',
    RiderSymbolKind.emoji => 'emoji:$emoji',
  };

  String wireValue(MotorcycleIconStyle motorcycleStyle) => switch (kind) {
    RiderSymbolKind.motorcycle => motorcycleStyle.name,
    _ => storageValue,
  };

  String label(String displayName, MotorcycleIconStyle motorcycleStyle) =>
      switch (kind) {
        RiderSymbolKind.motorcycle => motorcycleStyle.label,
        RiderSymbolKind.initials => 'Initials ${initialsFor(displayName)}',
        RiderSymbolKind.emoji => 'Emoji $emoji',
      };

  String initialsFor(String displayName) =>
      customInitials ?? riderInitials(displayName);

  RiderSymbol withInitials({
    String? customInitials,
    bool useAutomaticInitials = false,
    RiderInitialsInk? ink,
  }) => RiderSymbol.initials(
    customInitials: useAutomaticInitials
        ? null
        : customInitials ?? this.customInitials,
    initialsInk: ink ?? initialsInk,
  );

  String imageName(String displayName, MotorcycleIconStyle motorcycleStyle) {
    if (kind == RiderSymbolKind.motorcycle) return motorcycleStyle.name;
    final glyph = kind == RiderSymbolKind.initials
        ? initialsFor(displayName)
        : emoji!;
    final codePoints = glyph.runes
        .map((value) => value.toRadixString(16))
        .join('-');
    return 'rider-symbol-${kind.name}-$codePoints'
        '${kind == RiderSymbolKind.initials ? '-${initialsInk.name}' : ''}';
  }

  static RiderSymbol fromStorageValue(String? value) {
    if (value == 'initials') return const RiderSymbol.initials();
    if (value?.startsWith('initials:v1:') ?? false) {
      final parts = value!.split(':');
      if (parts.length != 4) return riderSymbolDefault;
      final initials = _decodeInitials(parts[2]);
      final ink = _riderInitialsInkFromName(parts[3]);
      if ((parts[2].isNotEmpty && initials == null) || ink == null) {
        return riderSymbolDefault;
      }
      return RiderSymbol.initials(customInitials: initials, initialsInk: ink);
    }
    if (value?.startsWith('emoji:') ?? false) {
      final emoji = value!.substring('emoji:'.length);
      if (riderEmojiChoices.contains(emoji)) return RiderSymbol.emoji(emoji);
    }
    return const RiderSymbol.motorcycle();
  }

  static RiderSymbol fromWireValue(String? value) {
    if (MotorcycleIconStyle.values.any((style) => style.name == value)) {
      return const RiderSymbol.motorcycle();
    }
    return fromStorageValue(value);
  }

  @override
  bool operator ==(Object other) =>
      other is RiderSymbol &&
      other.kind == kind &&
      other.emoji == emoji &&
      other.customInitials == customInitials &&
      other.initialsInk == initialsInk;

  @override
  int get hashCode => Object.hash(kind, emoji, customInitials, initialsInk);
}

const riderSymbolDefault = RiderSymbol.motorcycle();

/// A deliberately small, high-contrast catalogue that renders consistently on
/// both supported platforms and keeps the wire value comfortably below the
/// relay's existing 40-character motorcycle-style limit.
const riderEmojiChoices = <String>[
  '🏍️',
  '🛵',
  '🏁',
  '⚡',
  '🔥',
  '⭐',
  '🚀',
  '😎',
  '😈',
  '🐝',
  '🦊',
  '🐺',
  '🐉',
  '🦄',
  '🐢',
  '🦉',
  '🧭',
  '🏔️',
  '🦅',
  '🦁',
  '🐻',
  '🐙',
  '🍩',
  '🎯',
  '🤘',
  '💀',
  '👻',
  '🥷',
  '🦖',
  '🐸',
  '🌈',
  '☕',
];

/// Returns an uppercase 1–3 letter/number identity, or null for automatic
/// initials. Punctuation and control characters are deliberately excluded so
/// the compact wire value is safe to parse on Flutter and CarPlay.
String? normalizeCustomRiderInitials(String value) {
  final normalized = value.trim().toUpperCase();
  if (normalized.isEmpty) return null;
  final characters = normalized.characters.toList(growable: false);
  if (characters.length > 3) return null;
  final letterOrNumber = RegExp(r'^[\p{L}\p{N}]$', unicode: true);
  if (characters.any((character) => !letterOrNumber.hasMatch(character))) {
    return null;
  }
  // Keeps `initials:v1:<base64>:<ink>` below the existing 40-character
  // motorcycleStyle relay limit even for multi-byte letters.
  if (utf8.encode(normalized).length > 12) return null;
  return normalized;
}

String _encodeInitials(String? initials) {
  if (initials == null) return '';
  return base64Url.encode(utf8.encode(initials)).replaceAll('=', '');
}

String? _decodeInitials(String encoded) {
  if (encoded.isEmpty) return null;
  try {
    final padded = encoded.padRight((encoded.length + 3) ~/ 4 * 4, '=');
    return normalizeCustomRiderInitials(utf8.decode(base64Url.decode(padded)));
  } on FormatException {
    return null;
  }
}

RiderInitialsInk? _riderInitialsInkFromName(String name) {
  for (final ink in RiderInitialsInk.values) {
    if (ink.name == name) return ink;
  }
  return null;
}

String riderInitials(String displayName) {
  final words = displayName
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .toList(growable: false);
  if (words.isEmpty) return '?';
  if (words.length == 1) {
    return words.single.characters.take(2).toString().toUpperCase();
  }
  return '${words.first.characters.first}${words.last.characters.first}'
      .toUpperCase();
}

/// Side of the square PNG every rider glyph is rasterised into for the native
/// map.
const double riderSymbolRasterSize = 128;

/// The share of a rider badge's diameter that the rider's initials span.
///
/// This is the one number the whole app sizes initials by, and it exists
/// because there were three different answers to the same question (#259).
///
/// A bike or an emoji is a pictogram: it sits *inside* the badge, and every
/// symbol layer draws one at roughly 0.8 of the badge diameter. Initials are
/// not a pictogram — they are the rider's identity, and the point of #259 is
/// that they should fill the circle. They silently inherited the pictogram's
/// size on the native map, so they were drawn at about **0.76** of the badge
/// there, while the symbol picker's preview drew them at **0.94**. That is
/// both halves of the report at once: a quarter smaller than they should be,
/// and visibly not matching the preview a rider chose them from.
const double riderInitialsBadgeFill = 0.94;

/// `icon-size` for an initials raster drawn on a badge of [badgeDiameter].
///
/// [rasterizeRiderSymbolPng] already insets the glyph by
/// [riderInitialsBadgeFill] inside its own square, so the raster maps one to
/// one onto the badge and this is simply the ratio of the two. Derived rather
/// than tuned, so a change to a badge's radius cannot leave its initials
/// behind — which is exactly how they got left behind the first time.
double riderInitialsIconSize({
  required double badgeDiameter,
  double rasterSize = riderSymbolRasterSize,
}) => badgeDiameter / rasterSize;

/// A motorcycle glyph standing in for the plain circle/Material icon
/// previously used for rider map markers, tinted by the caller (role colour)
/// exactly like the `Icon` widget it replaces.
class MotorcycleIcon extends StatelessWidget {
  const MotorcycleIcon({
    super.key,
    required this.style,
    required this.color,
    this.size = 34,
  });

  final MotorcycleIconStyle style;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => ColorFiltered(
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    child: Image.asset(
      style.assetPath,
      width: size,
      height: size,
      fit: BoxFit.contain,
    ),
  );
}

/// A white bike silhouette on a filled circle in the rider's colour - reads
/// clearly against any basemap, unlike a flat-tinted icon alone, and matches
/// the badge look used for the "you are here" marker.
class RiderMarkerBadge extends StatelessWidget {
  const RiderMarkerBadge({
    super.key,
    required this.style,
    required this.badgeColor,
    this.symbol = riderSymbolDefault,
    this.displayName = '',
    this.size = 34,
    this.borderColor = RouteTrailStyle.casing,
    this.borderWidth = 2,
    this.glyphColor = RouteTrailStyle.markerGlyph,
  });

  final MotorcycleIconStyle style;
  final Color badgeColor;
  final RiderSymbol symbol;
  final String displayName;
  final double size;
  final Color borderColor;
  final double borderWidth;

  /// Ink for the motorcycle glyph inside the badge.
  final Color glyphColor;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: badgeColor,
      shape: BoxShape.circle,
      border: borderWidth <= 0
          ? null
          : Border.all(color: borderColor, width: borderWidth),
    ),
    child: Center(
      child: switch (symbol.kind) {
        RiderSymbolKind.motorcycle => MotorcycleIcon(
          style: style,
          // Dark, not white. Every badge fill is light because it has to be
          // found on a dark basemap, so a white glyph on top had almost no
          // contrast at all - 1.76:1 on the default rider green, 1.53:1 on
          // yellow. See `RouteTrailStyle.markerGlyph` (#133).
          color: glyphColor,
          size: size * 0.62,
        ),
        RiderSymbolKind.initials => Padding(
          // The same fill as the raster the native map draws, so the two
          // renderers of the same marker agree (#259). Measured against the
          // coloured circle rather than the widget's outer box, because the
          // border is drawn inside that box and the raster has no border at
          // all — basing it on the outer box left the two 6% apart.
          padding: EdgeInsets.all(
            (size - 2 * borderWidth) * (1 - riderInitialsBadgeFill) / 2,
          ),
          child: FittedBox(
            key: const Key('rider-marker-initials-fill'),
            fit: BoxFit.contain,
            child: Text(
              symbol.initialsFor(displayName),
              maxLines: 1,
              style: TextStyle(
                color: symbol.initialsInk.color,
                shadows: riderInitialsShadows(
                  symbol.initialsInk.color,
                  size * 0.025,
                ),
                // Start at the badge diameter, then let FittedBox use whichever
                // dimension is limiting. One and two letters therefore occupy
                // the circle instead of inheriting a body-text-sized glyph
                // (#259).
                fontSize: size,
                height: 0.9,
                fontWeight: FontWeight.w900,
                letterSpacing: -0.8,
              ),
            ),
          ),
        ),
        RiderSymbolKind.emoji => Text(
          symbol.emoji!,
          maxLines: 1,
          style: TextStyle(fontSize: size * 0.55, height: 1),
        ),
      },
    ),
  );
}

/// Raw PNG bytes for a style's asset, for registering with
/// `MapLibreMapController.addImage(name, bytes, sdf: true)` on the native
/// map. SDF images are tinted per-feature via the layer's `iconColor` paint
/// property, using only this asset's alpha channel as the shape mask.
Future<Uint8List> loadMotorcycleIconPng(MotorcycleIconStyle style) async {
  final data = await rootBundle.load(style.assetPath);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Future<({Uint8List bytes, bool sdf})> rasterizeRiderSymbolPng({
  required RiderSymbol symbol,
  required String displayName,
  required MotorcycleIconStyle motorcycleStyle,
  double size = riderSymbolRasterSize,
}) async {
  if (symbol.kind == RiderSymbolKind.motorcycle) {
    return (bytes: await loadMotorcycleIconPng(motorcycleStyle), sdf: true);
  }
  final glyph = symbol.kind == RiderSymbolKind.initials
      ? symbol.initialsFor(displayName)
      : symbol.emoji!;
  final initials = symbol.kind == RiderSymbolKind.initials;
  return (
    bytes: await _rasterizePng(
      size: size,
      paint: (canvas) {
        final painter = TextPainter(
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
          maxLines: 1,
          text: TextSpan(
            text: glyph,
            style: TextStyle(
              color: initials
                  ? symbol.initialsInk.color
                  : const Color(0xFFFFFFFF),
              fontSize: size * (initials ? 1 : 0.72),
              height: initials ? 0.9 : 1,
              fontWeight: initials ? FontWeight.w900 : FontWeight.normal,
              letterSpacing: initials ? -3 : null,
              shadows: initials
                  ? riderInitialsShadows(symbol.initialsInk.color, size * 0.012)
                  : null,
            ),
          ),
        )..layout();
        if (initials) {
          // The same fill the Flutter badge uses, so the raster is the badge
          // rather than something drawn inside it. The layer completes the
          // other half by scaling this square onto the badge itself; see
          // [riderInitialsIconSize].
          final available = size * riderInitialsBadgeFill;
          final scale = math.min(
            available / painter.width,
            available / painter.height,
          );
          final paintedWidth = painter.width * scale;
          final paintedHeight = painter.height * scale;
          canvas
            ..save()
            ..translate((size - paintedWidth) / 2, (size - paintedHeight) / 2)
            ..scale(scale);
          painter.paint(canvas, Offset.zero);
          canvas.restore();
          return;
        }
        painter.paint(
          canvas,
          Offset((size - painter.width) / 2, (size - painter.height) / 2),
        );
      },
    ),
    // Initials now carry rider-selected ink and their own contrast edge. A
    // non-SDF image preserves those colours; MapLibre ignores iconColor for it
    // just as it already does for emoji rasters.
    sdf: false,
  );
}

List<Shadow> riderInitialsShadows(Color ink, double offset) {
  final edge = ink.computeLuminance() > 0.48
      ? const Color(0xE610151C)
      : const Color(0xE6FFFFFF);
  return <Shadow>[
    Shadow(color: edge, offset: Offset(-offset, 0)),
    Shadow(color: edge, offset: Offset(offset, 0)),
    Shadow(color: edge, offset: Offset(0, -offset)),
    Shadow(color: edge, offset: Offset(0, offset)),
  ];
}

/// Renders an arbitrary Material icon glyph as a PNG, for markers (such as
/// hazards) that stay on the existing generic-icon style.
Future<Uint8List> rasterizeIconGlyphPng(IconData icon, {double size = 128}) =>
    _rasterizePng(
      size: size,
      paint: (canvas) {
        final painter = TextPainter(
          textDirection: TextDirection.ltr,
          text: TextSpan(
            text: String.fromCharCode(icon.codePoint),
            style: TextStyle(
              fontSize: size * 0.82,
              fontFamily: icon.fontFamily,
              package: icon.fontPackage,
              color: const Color(0xFFFFFFFF),
            ),
          ),
        )..layout();
        painter.paint(
          canvas,
          Offset((size - painter.width) / 2, (size - painter.height) / 2),
        );
      },
    );

Future<Uint8List> _rasterizePng({
  required double size,
  required void Function(Canvas canvas) paint,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  paint(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.round(), size.round());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../domain/rider_marker_outline.dart';
import 'ride_map_palette.dart';

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

/// The share of a marker badge's box a bike glyph spans, and the share an
/// emoji's font size is of it. These are the figures [RiderMarkerBadge] has
/// always drawn the glyph at; the native map reads them from here so a marker on
/// Android is the size of the same marker on iOS (#843).
const double riderGlyphBoxFill = 0.62;

/// See [riderGlyphBoxFill].
const double riderEmojiFontFill = 0.55;

/// Width in pixels of the bike asset the native map's glyph size is worked out
/// from. The fifteen bikes are 230 to 267 pixels wide, and the default's is the
/// nearest to their mean, so no style is more than 9% off the size it should be.
const double riderGlyphRasterWidth = 251;

/// The furthest MapLibre can draw an outline past the edge of a badge shape, in
/// the shape's own units (`icon-halo-width / icon-size`).
///
/// The shape is an SDF: its alpha encodes the distance to the edge, from 1 inside
/// to 0 six units outside, and the shader draws a halo of `icon-halo-width /
/// icon-size` of those units by thresholding that alpha. Asked for more than the
/// field holds, the threshold goes negative and the "outline" is the whole image:
/// a solid dark square behind every Android rider marker, and a white one behind
/// the local rider's (#843). The shader's edge softening needs a margin inside
/// the six, so the limit sits well under it. At the 34 box a rider's badge is
/// drawn in, this is about one logical pixel - what the flutter_map badge's
/// two pixel stroke shows outside its edge, the other pixel being inside it.
const double riderBadgeSdfHaloLimit = 4;

/// The `icon-halo-width` to give a badge shape of [badgeDiameter] asked for
/// [requested] logical pixels of outline: as much of it as the distance field
/// can hold.
double riderBadgeHaloWidth({
  required double badgeDiameter,
  required double requested,
}) => math.min(
  requested,
  riderBadgeSdfHaloLimit * badgeDiameter / riderMarkerShapeUnits,
);

/// The side of the box a badge shape is drawn in, in the units `icon-size` maps
/// onto the badge's diameter.
const double riderMarkerShapeUnits = 128;

/// `icon-size` for a bike glyph on a badge of [badgeDiameter], on a native map
/// that treats every image it is given as [pixelRatio] pixels to a logical pixel.
///
/// MapLibre draws an image `width / pixelRatio` logical pixels wide before
/// `icon-size` is applied, and the plugin's Android build gives every image the
/// device's density as its pixel ratio (`inDensity = 0` leaves the bitmap at the
/// device default; it does not mean one to one). The glyph's size was a constant
/// tuned on one phone, so it was right on that phone and wrong on every other
/// density, and the badge drawn beside it, rasterised as if the ratio were one,
/// came out `1 / pixelRatio` of its size - small enough for the glyph to hide it.
/// Derived from the ratio instead, the glyph comes out at [riderGlyphBoxFill] of
/// the badge on any density.
double riderGlyphIconSize({
  required double badgeDiameter,
  double pixelRatio = 1,
}) => badgeDiameter * riderGlyphBoxFill * pixelRatio / riderGlyphRasterWidth;

/// `icon-size` for an initials or emoji raster drawn on a badge of
/// [badgeDiameter], on a native map that treats every image as [pixelRatio]
/// pixels to a logical pixel.
///
/// [rasterizeRiderSymbolPng] already insets the glyph by
/// [riderInitialsBadgeFill] inside its own square, so the raster maps one to
/// one onto the badge and this is simply the ratio of the two - scaled by the
/// pixel ratio the native map divides the raster by. Derived rather than tuned,
/// so a change to a badge's radius cannot leave its initials behind — which is
/// exactly how they got left behind the first time.
double riderInitialsIconSize({
  required double badgeDiameter,
  double rasterSize = riderSymbolRasterSize,
  double pixelRatio = 1,
}) => badgeDiameter * pixelRatio / rasterSize;

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
    this.mapMarker = false,
    this.headingDegrees,
    this.mapBearingDegrees = 0,
    this.borderColor = RideMapPalette.otherRiderOutline,
    this.borderWidth = 2,
    this.glyphColor = RideMapPalette.glyphInk,
    this.outline = RiderMarkerOutline.circle,
  });

  final MotorcycleIconStyle style;
  final Color badgeColor;
  final RiderSymbol symbol;
  final String displayName;
  final double size;
  final bool mapMarker;
  final double? headingDegrees;
  final double mapBearingDegrees;
  final Color borderColor;
  final double borderWidth;

  /// Ink for the motorcycle glyph inside the badge.
  final Color glyphColor;

  /// A star for the leader and the Tail End Charlie, a circle for everyone else.
  /// Only a map marker takes it; the roster's badge stays a circle (#845).
  final RiderMarkerOutline outline;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: mapMarker
        ? RiderMarkerShapePainter(
            color: badgeColor,
            borderColor: borderColor,
            borderWidth: borderWidth,
            headingDegrees: headingDegrees,
            mapBearingDegrees: mapBearingDegrees,
            outline: outline,
          )
        : null,
    child: Container(
      width: size,
      height: size,
      decoration: mapMarker
          ? null
          : BoxDecoration(
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
            size: size * riderGlyphBoxFill,
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
            style: TextStyle(fontSize: size * riderEmojiFontFill, height: 1),
          ),
        },
      ),
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
              fontSize: size * (initials ? 1 : riderEmojiFontFill),
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
/// The side, in pixels, of the square [rasterizeIconGlyphPng] draws a glyph into.
const double iconGlyphRasterSize = 128;

/// The share of that square the glyph's em box fills, so a glyph drawn at a
/// `fontSize` of [iconGlyphRasterSize] times this is the size the Flutter `Icon`
/// widget draws at the same `size`.
const double iconGlyphFontShare = 0.82;

/// `icon-size` that draws a glyph rasterised by [rasterizeIconGlyphPng] at
/// [glyphSize] logical pixels - the `size` an `Icon` widget would be given - on a
/// native map that treats every image as [pixelRatio] pixels to a logical pixel.
///
/// MapLibre draws an image `width / pixelRatio` logical pixels wide before
/// `icon-size` applies (see `_nativeMarkerPixelRatio` in `ride_map_feature.dart`),
/// so a constant `icon-size` is right on one density and wrong on every other:
/// the trail direction arrows' `0.15` was seven logical pixels on a three-pixel
/// phone where iOS draws eighteen (#900).
double iconGlyphIconSize({
  required double glyphSize,
  double pixelRatio = 1,
  double rasterSize = iconGlyphRasterSize,
}) => glyphSize * pixelRatio / (rasterSize * iconGlyphFontShare);

Future<Uint8List> rasterizeIconGlyphPng(
  IconData icon, {
  double size = iconGlyphRasterSize,
}) => _rasterizePng(
  size: size,
  paint: (canvas) {
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: size * iconGlyphFontShare,
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

/// Only moving, current fixes support a direction-of-travel claim.
double? riderTravelHeading({
  double? headingDegrees,
  double? speedMetersPerSecond,
  bool fresh = true,
}) {
  if (!fresh ||
      headingDegrees == null ||
      !headingDegrees.isFinite ||
      headingDegrees < 0 ||
      headingDegrees >= 360 ||
      speedMetersPerSecond == null ||
      !speedMetersPerSecond.isFinite ||
      speedMetersPerSecond < 1.5) {
    return null;
  }
  return headingDegrees;
}

const riderDirectionShapeImage = 'tec-rider-direction';
const riderUnknownShapeImage = 'tec-rider-unknown';
const riderStarDirectionShapeImage = 'tec-rider-star-direction';
const riderStarUnknownShapeImage = 'tec-rider-star-unknown';

/// The `icon-image` expression for a rider's badge shape: a star where the
/// feature's `outline` property says so, a circle otherwise, and the pointed or
/// the neutral variant of either by whether the feature has a `bearing`.
const List<Object> riderShapeImageExpression = <Object>[
  'case',
  <Object>[
    '==',
    <Object>['get', 'outline'],
    'star',
  ],
  <Object>[
    'case',
    <Object>['has', 'bearing'],
    riderStarDirectionShapeImage,
    riderStarUnknownShapeImage,
  ],
  <Object>[
    'case',
    <Object>['has', 'bearing'],
    riderDirectionShapeImage,
    riderUnknownShapeImage,
  ],
];

/// The name the native map registers a badge shape under.
String riderMarkerShapeImageName({
  required RiderMarkerOutline outline,
  required bool directional,
}) => switch ((outline, directional)) {
  (RiderMarkerOutline.circle, true) => riderDirectionShapeImage,
  (RiderMarkerOutline.circle, false) => riderUnknownShapeImage,
  (RiderMarkerOutline.star, true) => riderStarDirectionShapeImage,
  (RiderMarkerOutline.star, false) => riderStarUnknownShapeImage,
};

/// Pointed badge for travel; a circle makes no heading claim at rest. The leader
/// and the Tail End Charlie are stars instead of circles (#845).
/// Rotate only the background so initials and emoji always remain upright.
class RiderMarkerShapePainter extends CustomPainter {
  const RiderMarkerShapePainter({
    required this.color,
    this.borderColor = Colors.black,
    this.borderWidth = 2,
    this.headingDegrees,
    this.mapBearingDegrees = 0,
    this.outline = RiderMarkerOutline.circle,
  });
  final Color color;
  final Color borderColor;
  final double borderWidth;
  final double? headingDegrees;
  final double mapBearingDegrees;
  final RiderMarkerOutline outline;

  /// How far out each point of a resting star reaches, as a share of half the
  /// box. The circle fills 0.8 of it; a star's points are narrow, so these reach
  /// past the box: a star that were no bigger than the circle would be the less
  /// conspicuous marker, and at 34 pixels it needs points that are longer than
  /// the body is wide to read as a star at all rather than as a pentagon.
  static const starTipShare = 1.06;

  /// How deep the valleys between the points are, which is the radius of the
  /// body of the star. The bike glyph inside stays upright while a moving star
  /// turns, so it has to fit at every heading: at 0.66 every bike does, at every
  /// ten degrees (the test measures it), and at 0.62 a wheel of the scooter
  /// spills half a pixel.
  static const starValleyShare = 0.66;

  /// A moving star turns into itself every 72 degrees, so on its own it could
  /// not say which way the bike is going - the job the pointer's nose does for a
  /// circle (#777). It leads with one longer point instead: the forward point
  /// reaches [starNoseShare] and the other four stop at [starMovingTipShare].
  /// The valleys stay where they are, so the glyph has the same room at every
  /// heading, and it is still a star at every heading with one point that is
  /// plainly the front.
  static const starMovingTipShare = 1.02;

  /// See [starMovingTipShare].
  static const starNoseShare = 1.26;

  /// How much the corners of the star are rounded, so the outline has no sharp
  /// joins to bleed. Little, because the points are what makes it a star.
  static const starCornerShare = 0.06;

  static Path shape(
    Size size, {
    required bool directional,
    RiderMarkerOutline outline = RiderMarkerOutline.circle,
  }) {
    if (outline == RiderMarkerOutline.star) {
      return _star(size, directional: directional);
    }
    if (!directional) {
      return Path()..addOval(
        Rect.fromLTWH(
          size.width * .1,
          size.height * .1,
          size.width * .8,
          size.height * .8,
        ),
      );
    }
    // Keep a broad body for an upright bike/initials glyph at every rotation.
    // A narrow triangle clipped the identity; the long pointed nose supplies
    // direction while the rounded body protects the readable centre.
    return Path()
      ..moveTo(size.width * .5, size.height * .02)
      ..lineTo(size.width * .84, size.height * .32)
      ..cubicTo(
        size.width * 1.02,
        size.height * .55,
        size.width * .88,
        size.height * .96,
        size.width * .5,
        size.height * .96,
      )
      ..cubicTo(
        size.width * .12,
        size.height * .96,
        size.width * -.02,
        size.height * .55,
        size.width * .16,
        size.height * .32,
      )
      ..close();
  }

  /// A five-pointed star, one point up, in the box the circle and the pointer fill.
  static Path _star(Size size, {required bool directional}) {
    final centre = Offset(size.width / 2, size.height / 2);
    final half = size.shortestSide / 2;
    // Even indices are points (index 0 is the one pointing up), odd ones the
    // valleys between them.
    double reach(int index) {
      if (!directional) {
        return index.isOdd ? starValleyShare : starTipShare;
      }
      if (index == 0) return starNoseShare;
      return index.isOdd ? starValleyShare : starMovingTipShare;
    }

    final vertices = <Offset>[
      for (var index = 0; index < 10; index++)
        centre +
            Offset(
                  math.cos(-math.pi / 2 + index * math.pi / 5),
                  math.sin(-math.pi / 2 + index * math.pi / 5),
                ) *
                (half * reach(index)),
    ];
    return _roundedPolygon(vertices, half * starCornerShare);
  }

  /// [points] joined by straight edges with each corner cut and rounded by up to
  /// [radius], never more than half of either edge.
  static Path _roundedPolygon(List<Offset> points, double radius) {
    final path = Path();
    for (var index = 0; index < points.length; index++) {
      final vertex = points[index];
      final toPrevious =
          points[(index + points.length - 1) % points.length] - vertex;
      final toNext = points[(index + 1) % points.length] - vertex;
      final cut = math.min(
        radius,
        math.min(toPrevious.distance, toNext.distance) / 2,
      );
      final entry = vertex + toPrevious / toPrevious.distance * cut;
      final exit = vertex + toNext / toNext.distance * cut;
      if (index == 0) {
        path.moveTo(entry.dx, entry.dy);
      } else {
        path.lineTo(entry.dx, entry.dy);
      }
      path.quadraticBezierTo(vertex.dx, vertex.dy, exit.dx, exit.dy);
    }
    return path..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final heading = headingDegrees;
    canvas.save();
    if (heading != null && heading.isFinite) {
      canvas.translate(size.width / 2, size.height / 2);
      canvas.rotate((heading - mapBearingDegrees) * math.pi / 180);
      canvas.translate(-size.width / 2, -size.height / 2);
    }
    final path = shape(
      size,
      directional: heading != null && heading.isFinite,
      outline: outline,
    );
    canvas.drawPath(path, Paint()..color = color);
    if (borderWidth > 0) {
      canvas.drawPath(
        path,
        Paint()
          ..color = borderColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = borderWidth
          // The native map's outline is a halo around a distance field, which is
          // round at every corner; a mitred star would show spikes it does not.
          ..strokeJoin = outline == RiderMarkerOutline.star
              ? StrokeJoin.round
              : StrokeJoin.miter,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(RiderMarkerShapePainter old) =>
      color != old.color ||
      borderColor != old.borderColor ||
      borderWidth != old.borderWidth ||
      headingDegrees != old.headingDegrees ||
      mapBearingDegrees != old.mapBearingDegrees ||
      outline != old.outline;
}

// MapLibre colours and outlines SDF images using distance encoded in alpha,
// not a normal opaque silhouette. Keep an eight-pixel distance band and padding
// at 1x; the plugin treats iOS images as device-density sprites.
final _riderShapeRasters =
    <(bool, RiderMarkerOutline, double), Future<Uint8List>>{};

Future<Uint8List> rasterizeRiderMarkerShapePng({
  required bool directional,
  RiderMarkerOutline outline = RiderMarkerOutline.circle,
  double pixelRatio = 1,
}) => _riderShapeRasters.putIfAbsent((
  directional,
  outline,
  pixelRatio,
), () => _rasterizeRiderShapeSdf(directional, outline, pixelRatio));
Future<Uint8List> _rasterizeRiderShapeSdf(
  bool directional,
  RiderMarkerOutline outline,
  double pixelRatio,
) async {
  // A star's points reach past the box the circle fills, the forward one by a
  // quarter of it, so its raster has more room around the box to keep the whole
  // distance band.
  final padding = outline == RiderMarkerOutline.star ? 24.0 : 8.0;
  final side = (riderMarkerShapeUnits + 2 * padding).round();
  final path = RiderMarkerShapePainter.shape(
    const Size.square(128),
    directional: directional,
    outline: outline,
  ).shift(Offset(padding, padding));
  final segments = <(Offset, Offset)>[];
  for (final metric in path.computeMetrics()) {
    var previous = metric.getTangentForOffset(0)!.position;
    for (var distance = 1.0; distance < metric.length + 1; distance += 1) {
      final next = metric
          .getTangentForOffset(math.min(distance, metric.length))!
          .position;
      segments.add((previous, next));
      previous = next;
    }
  }
  final pixels = Uint8List(side * side * 4);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final point = Offset(x + .5, y + .5);
      var nearestSquared = double.infinity;
      for (final (a, b) in segments) {
        final delta = b - a;
        final lengthSquared = delta.distanceSquared;
        if (lengthSquared == 0) continue;
        final relative = point - a;
        final t =
            ((relative.dx * delta.dx + relative.dy * delta.dy) / lengthSquared)
                .clamp(0.0, 1.0);
        nearestSquared = math.min(
          nearestSquared,
          (point - (a + delta * t)).distanceSquared,
        );
      }
      final distance =
          math.sqrt(nearestSquared) * (path.contains(point) ? 1 : -1);
      final alpha = (255 * (.75 + distance / 8)).round().clamp(0, 255);
      final index = (y * side + x) * 4;
      // Premultiplied white; only alpha is consumed by the native SDF shader.
      pixels.fillRange(index, index + 4, alpha);
    }
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
  final descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: side,
    height: side,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final codec = await descriptor.instantiateCodec();
  final image = (await codec.getNextFrame()).image;
  try {
    return await _rasterizePng(
      size: side * pixelRatio,
      paint: (canvas) {
        canvas.scale(pixelRatio);
        canvas.drawImage(
          image,
          Offset.zero,
          Paint()..filterQuality = FilterQuality.low,
        );
      },
    );
  } finally {
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

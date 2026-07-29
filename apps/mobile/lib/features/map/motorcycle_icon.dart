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

/// How a rider identifies themselves inside their coloured marker badge.
///
/// The wire representation deliberately reuses the existing
/// `motorcycleStyle` string. Old builds therefore see an unknown style and
/// safely fall back to the default bike, while new builds can show initials or
/// an emoji without requiring a relay protocol migration.
class RiderSymbol {
  const RiderSymbol.motorcycle()
    : kind = RiderSymbolKind.motorcycle,
      emoji = null;

  const RiderSymbol.initials() : kind = RiderSymbolKind.initials, emoji = null;

  const RiderSymbol.emoji(this.emoji)
    : kind = RiderSymbolKind.emoji,
      assert(emoji != null && emoji != '');

  final RiderSymbolKind kind;
  final String? emoji;

  String get storageValue => switch (kind) {
    RiderSymbolKind.motorcycle => 'motorcycle',
    RiderSymbolKind.initials => 'initials',
    RiderSymbolKind.emoji => 'emoji:$emoji',
  };

  String wireValue(MotorcycleIconStyle motorcycleStyle) => switch (kind) {
    RiderSymbolKind.motorcycle => motorcycleStyle.name,
    _ => storageValue,
  };

  String label(String displayName, MotorcycleIconStyle motorcycleStyle) =>
      switch (kind) {
        RiderSymbolKind.motorcycle => motorcycleStyle.label,
        RiderSymbolKind.initials => 'Initials ${riderInitials(displayName)}',
        RiderSymbolKind.emoji => 'Emoji $emoji',
      };

  String imageName(String displayName, MotorcycleIconStyle motorcycleStyle) {
    if (kind == RiderSymbolKind.motorcycle) return motorcycleStyle.name;
    final glyph = kind == RiderSymbolKind.initials
        ? riderInitials(displayName)
        : emoji!;
    final codePoints = glyph.runes
        .map((value) => value.toRadixString(16))
        .join('-');
    return 'rider-symbol-${kind.name}-$codePoints';
  }

  static RiderSymbol fromStorageValue(String? value) {
    if (value == 'initials') return const RiderSymbol.initials();
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
      other is RiderSymbol && other.kind == kind && other.emoji == emoji;

  @override
  int get hashCode => Object.hash(kind, emoji);
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
];

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
          padding: EdgeInsets.all(size * 0.08),
          child: FittedBox(
            key: const Key('rider-marker-initials-fill'),
            fit: BoxFit.contain,
            child: Text(
              riderInitials(displayName),
              maxLines: 1,
              style: TextStyle(
                color: glyphColor,
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
  double size = 128,
}) async {
  if (symbol.kind == RiderSymbolKind.motorcycle) {
    return (bytes: await loadMotorcycleIconPng(motorcycleStyle), sdf: true);
  }
  final glyph = symbol.kind == RiderSymbolKind.initials
      ? riderInitials(displayName)
      : symbol.emoji!;
  final initials = symbol.kind == RiderSymbolKind.initials;
  return (
    bytes: await _rasterizePng(
      size: size,
      paint: (canvas) {
        final painter = TextPainter(
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.center,
          text: TextSpan(
            text: glyph,
            style: TextStyle(
              color: const Color(0xFFFFFFFF),
              fontSize: size * (initials ? 1 : 0.72),
              height: initials ? 0.9 : 1,
              fontWeight: initials ? FontWeight.w900 : FontWeight.normal,
              letterSpacing: initials ? -3 : null,
            ),
          ),
        )..layout(maxWidth: size);
        if (initials) {
          final available = size * 0.84;
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
    sdf: initials,
  );
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

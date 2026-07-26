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
    this.size = 34,
    this.borderColor = RouteTrailStyle.casing,
    this.borderWidth = 2,
    this.glyphColor = RouteTrailStyle.markerGlyph,
  });

  final MotorcycleIconStyle style;
  final Color badgeColor;
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
      child: MotorcycleIcon(
        style: style,
        // Dark, not white. Every badge fill is light because it has to be found
        // on a dark basemap, so a white glyph on top had almost no contrast at
        // all - 1.76:1 on the default rider green, 1.53:1 on yellow. See
        // `RouteTrailStyle.markerGlyph`, which owns the measurement (#133).
        color: glyphColor,
        size: size * 0.62,
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

import 'package:flutter/material.dart';

/// Colours a rider can personally choose.
///
/// The selected colour is their identity on every roster and map surface.
/// Roles and alerts use labels, borders and icons rather than replacing it.
enum RiderColor {
  green,
  orange,
  yellow,
  teal,
  pink,
  cyan,
  amber,
  crimson,
  purple,
  white,
  blue,
  lime,
  slate,
}

extension RiderColorData on RiderColor {
  Color get color => switch (this) {
    RiderColor.green => const Color(0xFF6ED89A),
    RiderColor.orange => const Color(0xFFFF9F5A),
    RiderColor.yellow => const Color(0xFFE8D24C),
    RiderColor.teal => const Color(0xFF4FC7C7),
    RiderColor.pink => const Color(0xFFE87FC0),
    RiderColor.cyan => const Color(0xFF5AC8FA),
    RiderColor.amber => const Color(0xFFD9A441),
    RiderColor.crimson => const Color(0xFFD9607A),
    RiderColor.purple => const Color(0xFF9B7BFF),
    RiderColor.white => const Color(0xFFF4F6F8),
    RiderColor.blue => const Color(0xFF5B8DEF),
    RiderColor.lime => const Color(0xFFA7D957),
    RiderColor.slate => const Color(0xFF8796A8),
  };

  String get label => switch (this) {
    RiderColor.green => 'Green',
    RiderColor.orange => 'Orange',
    RiderColor.yellow => 'Yellow',
    RiderColor.teal => 'Teal',
    RiderColor.pink => 'Pink',
    RiderColor.cyan => 'Sky blue',
    RiderColor.amber => 'Amber',
    RiderColor.crimson => 'Crimson',
    RiderColor.purple => 'Purple',
    RiderColor.white => 'White',
    RiderColor.blue => 'Blue',
    RiderColor.lime => 'Lime',
    RiderColor.slate => 'Slate',
  };
}

/// White and near-white badges need a dark edge; the other light identity
/// colours retain the familiar white selection/position edge.
Color riderBadgeStrokeColor(Color fill) =>
    fill.computeLuminance() > 0.82 ? const Color(0xFF10151C) : Colors.white;

/// Default for sessions created before this feature existed, and the
/// fallback when a peer sends an unrecognised colour name. Matches the
/// green riders have always shown as.
const riderColorDefault = RiderColor.green;

RiderColor riderColorFromName(String? name) => RiderColor.values.firstWhere(
  (value) => value.name == name,
  orElse: () => riderColorDefault,
);

/// Reserved status colours that never come from a rider's personal choice.
/// They remain available for role/alert accents without replacing identity.
const leadColor = Color(0xFFB58CFF);
const tailEndCharlieColor = Color(0xFF68A9FF);
const alertColor = Color(0xFFFF5D73);

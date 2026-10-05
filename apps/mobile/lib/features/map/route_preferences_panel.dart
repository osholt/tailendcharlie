import 'package:flutter/material.dart';

import '../../domain/route_preferences.dart';

/// The route options on the plan surface (#847).
///
/// The same preferences as the web planner, so a route planned here and one
/// planned on the website mean the same thing (#182). They used to be a form a
/// rider filled in before seeing any route; on the plan surface each change
/// re-plans the route in front of them.
class RoutePreferencesPanel extends StatelessWidget {
  const RoutePreferencesPanel({
    super.key,
    required this.preferences,
    required this.onChanged,
    this.enabled = true,
  });

  final RoutePreferences preferences;
  final ValueChanged<RoutePreferences> onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      DropdownButtonFormField<RouteStyle>(
        key: const Key('route-style-field'),
        initialValue: preferences.style,
        decoration: const InputDecoration(labelText: 'Routing style'),
        items: RouteStyle.values
            .map(
              (style) =>
                  DropdownMenuItem(value: style, child: Text(style.label)),
            )
            .toList(growable: false),
        onChanged: enabled
            ? (value) {
                if (value != null && value != preferences.style) {
                  onChanged(preferences.copyWith(style: value));
                }
              }
            : null,
      ),
      SwitchListTile(
        key: const Key('avoid-motorways-switch'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Avoid motorways'),
        value: preferences.avoidMotorways,
        onChanged: enabled
            ? (value) => onChanged(preferences.copyWith(avoidMotorways: value))
            : null,
      ),
      SwitchListTile(
        key: const Key('avoid-major-roads-switch'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Avoid major roads'),
        subtitle: const Text('The quieter-road option.'),
        value: preferences.avoidMajorRoads,
        onChanged: enabled
            ? (value) => onChanged(preferences.copyWith(avoidMajorRoads: value))
            : null,
      ),
      SwitchListTile(
        key: const Key('avoid-tolls-switch'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Avoid toll roads'),
        value: preferences.avoidTolls,
        onChanged: enabled
            ? (value) => onChanged(preferences.copyWith(avoidTolls: value))
            : null,
      ),
      SwitchListTile(
        key: const Key('avoid-ferries-switch'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Avoid ferries'),
        value: preferences.avoidFerries,
        onChanged: enabled
            ? (value) => onChanged(preferences.copyWith(avoidFerries: value))
            : null,
      ),
      SwitchListTile(
        key: const Key('avoid-unsurfaced-byways-switch'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Avoid unsurfaced byways'),
        subtitle: const Text(
          'On by default. A byway open to all traffic is legal to ride but '
          'often unsurfaced. Turn this off to allow ways OpenStreetMap tags as '
          'unsurfaced or as a track.',
        ),
        value: preferences.bywaySurface.avoidsUnsurfaced,
        onChanged: enabled
            ? (value) => onChanged(
                preferences.copyWith(
                  bywaySurface: value
                      ? BywaySurfacePreference.avoidUnsurfaced
                      : BywaySurfacePreference.allowUnsurfaced,
                ),
              )
            : null,
      ),
    ],
  );
}

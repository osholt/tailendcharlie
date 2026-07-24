import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../controllers/distance_unit_controller.dart';
import '../../controllers/map_style_mode_controller.dart';
import '../../controllers/rider_profile_controller.dart';
import '../../controllers/speed_limit_display_controller.dart';
import '../../domain/distance_unit.dart';
import '../../domain/map_style_mode.dart';
import '../../domain/rider_color.dart';
import '../../services/basemap_configuration.dart';
import '../map/motorcycle_icon.dart';
import 'rider_profile_sheet.dart';

class UnitSettingsSheet extends StatelessWidget {
  const UnitSettingsSheet({
    super.key,
    required this.controller,
    required this.mapStyleMode,
    required this.riderProfile,
    required this.speedLimitDisplay,
    this.currentRideActive = false,
  });

  final DistanceUnitController controller;
  final MapStyleModeController mapStyleMode;
  final RiderProfileController riderProfile;
  final SpeedLimitDisplayController speedLimitDisplay;
  final bool currentRideActive;

  static Future<void> show(
    BuildContext context,
    DistanceUnitController controller,
    MapStyleModeController mapStyleMode,
    RiderProfileController riderProfile, {
    required SpeedLimitDisplayController speedLimitDisplay,
    bool currentRideActive = false,
  }) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => UnitSettingsSheet(
      controller: controller,
      mapStyleMode: mapStyleMode,
      riderProfile: riderProfile,
      speedLimitDisplay: speedLimitDisplay,
      currentRideActive: currentRideActive,
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([controller, mapStyleMode, speedLimitDisplay]),
    builder: (context, _) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 20),
          Text(
            'RIDER PROFILE',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: const Color(0xFF8D98A7),
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          ListTile(
            key: const Key('open-rider-profile'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.two_wheeler),
            title: Text(
              riderProfile.displayName.isEmpty
                  ? 'Set up rider profile'
                  : riderProfile.displayName,
            ),
            subtitle: Text(
              '${riderProfile.motorcycleStyle.label} · ${riderProfile.riderColor.label}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              final appContext = Navigator.of(
                context,
                rootNavigator: true,
              ).context;
              Navigator.of(context).pop();
              unawaited(
                RiderProfileSheet.show(
                  appContext,
                  riderProfile,
                  currentRideActive: currentRideActive,
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Text(
            'DISTANCE UNITS',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: const Color(0xFF8D98A7),
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 10),
          SegmentedButton<DistanceUnit>(
            key: const Key('distance-unit-selector'),
            segments: DistanceUnit.values
                .map(
                  (unit) => ButtonSegment<DistanceUnit>(
                    value: unit,
                    label: Text(unit.label),
                  ),
                )
                .toList(growable: false),
            selected: {controller.value},
            onSelectionChanged: (selection) {
              unawaited(controller.setUnit(selection.single));
            },
          ),
          const SizedBox(height: 12),
          Text(
            controller.followsLocale
                ? 'Using the device locale default (${controller.localeDefault.label.toLowerCase()}).'
                : 'Overriding the device locale default (${controller.localeDefault.label.toLowerCase()}).',
            style: const TextStyle(color: Color(0xFF98A3B1)),
          ),
          if (!controller.followsLocale) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('use-locale-distance-unit'),
                onPressed: () => unawaited(controller.useLocaleDefault()),
                child: const Text('Use locale default'),
              ),
            ),
          ],
          const SizedBox(height: 22),
          Text(
            'MAP APPEARANCE',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: const Color(0xFF8D98A7),
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 10),
          SegmentedButton<MapStyleMode>(
            key: const Key('map-style-mode-selector'),
            segments: MapStyleMode.values
                .map(
                  (mode) => ButtonSegment<MapStyleMode>(
                    value: mode,
                    label: Text(mode.label),
                  ),
                )
                .toList(growable: false),
            selected: {mapStyleMode.value},
            onSelectionChanged: (selection) {
              unawaited(mapStyleMode.setMode(selection.single));
            },
          ),
          const SizedBox(height: 12),
          Text(
            _mapAppearanceStatus(context, mapStyleMode),
            style: const TextStyle(color: Color(0xFF98A3B1)),
          ),
          const SizedBox(height: 18),
          SwitchListTile.adaptive(
            key: const Key('posted-speed-limit-toggle'),
            contentPadding: EdgeInsets.zero,
            value: speedLimitDisplay.enabled,
            onChanged: speedLimitDisplay.setEnabled,
            title: const Text('Show mapped speed limit'),
            subtitle: const Text(
              'Opt in to UK road matching using © OpenStreetMap contributors '
              'via Valhalla. Mapped limits are not live; roadside signs '
              'always apply.',
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'MAP DATA',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: const Color(0xFF8D98A7),
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            BasemapConfiguration.fromEnvironment().attribution,
            style: const TextStyle(color: Color(0xFF98A3B1), fontSize: 12),
          ),
          const SizedBox(height: 22),
          Text(
            'ABOUT',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: const Color(0xFF8D98A7),
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 4,
              children: [
                TextButton(
                  key: const Key('open-privacy-policy'),
                  onPressed: () =>
                      unawaited(_openLegalPage(context, 'privacy.html')),
                  child: const Text('Privacy Policy'),
                ),
                TextButton(
                  key: const Key('open-terms-of-use'),
                  onPressed: () =>
                      unawaited(_openLegalPage(context, 'terms.html')),
                  child: const Text('Terms of Use'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> _openLegalPage(BuildContext context, String page) async {
  final opened = await launchUrl(
    Uri.https('tailendcharlie.app', '/$page'),
    mode: LaunchMode.externalApplication,
  );
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Could not open the page.')));
  }
}

String _mapAppearanceStatus(
  BuildContext context,
  MapStyleModeController mapStyleMode,
) {
  final resolvedDark = mapStyleMode.resolveDark(
    MediaQuery.platformBrightnessOf(context),
  );
  return switch (mapStyleMode.value) {
    MapStyleMode.system =>
      'Matching your device: currently ${resolvedDark ? 'dark' : 'light'}.',
    MapStyleMode.sunriseSunset =>
      mapStyleMode.hasSunPosition
          ? 'Following sunrise/sunset: currently ${resolvedDark ? 'dark' : 'light'}.'
          : "Following sunrise/sunset - waiting for a location fix; matching "
                'your device for now.',
    MapStyleMode.light ||
    MapStyleMode.dark => 'Takes effect next time you open the map.',
  };
}

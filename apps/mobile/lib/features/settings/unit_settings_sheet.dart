import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../controllers/distance_unit_controller.dart';
import '../../controllers/map_style_mode_controller.dart';
import '../../controllers/rider_profile_controller.dart';
import '../../controllers/speed_limit_display_controller.dart';
import '../../controllers/ride_diagnostics_controller.dart';
import '../../controllers/spoken_guidance_controller.dart';
import '../../controllers/test_control_controller.dart';
import '../../domain/distance_unit.dart';
import '../../domain/map_style_mode.dart';
import '../../domain/rider_color.dart';
import '../../services/basemap_configuration.dart';
import '../../services/build_identity.dart';
import '../../services/spoken_guidance.dart';
import 'about_build_sheet.dart';
import 'rider_profile_sheet.dart';
import 'ride_diagnostics_section.dart';
import 'test_control_section.dart';

class UnitSettingsSheet extends StatelessWidget {
  const UnitSettingsSheet({
    super.key,
    required this.controller,
    required this.mapStyleMode,
    required this.riderProfile,
    required this.speedLimitDisplay,
    this.currentRideActive = false,
    this.lastRelaySync,
    this.buildIdentity,
    this.testControl,
    this.spokenGuidance,
    this.rideDiagnostics,
    this.embedded = false,
  });

  final DistanceUnitController controller;
  final MapStyleModeController mapStyleMode;
  final RiderProfileController riderProfile;
  final SpeedLimitDisplayController speedLimitDisplay;
  final bool currentRideActive;

  /// Whether these settings are the body of a primary destination rather than
  /// a dismissible sheet. Nested editors must not pop the active ride when
  /// Settings occupies the bottom-bar slot (#306).
  final bool embedded;

  /// Whether turn instructions are spoken. Off by default: most riders already
  /// have an intercom carrying music or another app's prompts, and a second
  /// uninvited voice is worse than silence (#286).
  final SpokenGuidanceController? spokenGuidance;

  /// Off, and absent from an ordinary build (#419).
  final RideDiagnosticsController? rideDiagnostics;

  /// Present only in a build carrying the test-control define. Null everywhere
  /// else, and [TestControlSection] renders nothing when the define is absent,
  /// so an ordinary build shows no trace of this surface.
  final TestControlController? testControl;

  /// Most recent successful relay sync, when the caller knows it. Shown on the
  /// About & build sheet so a bug report can say whether the app was talking to
  /// the relay at all.
  final DateTime? lastRelaySync;

  /// Injected in tests; production reads the stamped-in dart-defines.
  final BuildIdentity? buildIdentity;

  static Future<void> show(
    BuildContext context,
    DistanceUnitController controller,
    MapStyleModeController mapStyleMode,
    RiderProfileController riderProfile, {
    required SpeedLimitDisplayController speedLimitDisplay,
    bool currentRideActive = false,
    DateTime? lastRelaySync,
    BuildIdentity? buildIdentity,
    TestControlController? testControl,
    SpokenGuidanceController? spokenGuidance,
    RideDiagnosticsController? rideDiagnostics,
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
      lastRelaySync: lastRelaySync,
      buildIdentity: buildIdentity,
      testControl: testControl,
      spokenGuidance: spokenGuidance,
      rideDiagnostics: rideDiagnostics,
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
              '${riderProfile.riderSymbol.label(riderProfile.displayName, riderProfile.motorcycleStyle)} · ${riderProfile.riderColor.label}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              final appContext = Navigator.of(
                context,
                rootNavigator: true,
              ).context;
              if (!embedded) Navigator.of(context).pop();
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
          Text(
            'DAYTIME MAP',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: const Color(0xFF8D98A7),
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 10),
          SegmentedButton<DayMapStyle>(
            key: const Key('day-map-style-selector'),
            segments: DayMapStyle.values
                .map(
                  (style) => ButtonSegment<DayMapStyle>(
                    value: style,
                    label: Text(style.label),
                  ),
                )
                .toList(growable: false),
            selected: {mapStyleMode.dayStyle},
            onSelectionChanged: (selection) {
              unawaited(mapStyleMode.setDayStyle(selection.single));
            },
          ),
          const SizedBox(height: 10),
          const Text(
            'Restrained uses the quieter road-first daytime palette. Original '
            'keeps the OpenFreeMap Liberty colours. This applies whenever the '
            'map is in light or sun-based daytime mode.',
            style: TextStyle(color: Color(0xFF98A3B1)),
          ),
          const SizedBox(height: 18),
          SwitchListTile.adaptive(
            key: const Key('posted-speed-limit-toggle'),
            contentPadding: EdgeInsets.zero,
            value: speedLimitDisplay.enabled,
            onChanged: speedLimitDisplay.setEnabled,
            title: const Text('Show mapped speed limit'),
            subtitle: const Text(
              'On by default. Matches your position and up to 1 km ahead to '
              'roads in Great Britain and the Isle of Man using © OpenStreetMap '
              'contributors via Valhalla. Mapped limits are not live; roadside '
              'signs always apply. Turning this off is remembered.',
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
            'GUIDANCE',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: const Color(0xFF8D98A7),
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          if (spokenGuidance case final spoken?)
            Column(
              children: [
                AnimatedBuilder(
                  animation: spoken,
                  builder: (context, _) => SwitchListTile.adaptive(
                    key: const Key('spoken-guidance-toggle'),
                    contentPadding: EdgeInsets.zero,
                    value: spoken.enabled,
                    onChanged: spoken.setEnabled,
                    title: const Text('Speak turn instructions'),
                    subtitle: const Text(
                      'Reads the next turn aloud so you do not have to look '
                      'down. Mixes with music or an intercom rather than '
                      'stopping it.',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _SpokenVoiceSetting(controller: spoken),
              ],
            ),
          const SizedBox(height: 20),
          Text(
            'ABOUT',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: const Color(0xFF8D98A7),
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 4),
          if (testControl case final testControl?)
            TestControlSection(controller: testControl),
          if (rideDiagnostics case final diagnostics?)
            RideDiagnosticsSection(controller: diagnostics),
          _AboutBuildTile(
            identity: buildIdentity ?? BuildIdentity.fromEnvironment(),
            lastRelaySync: lastRelaySync,
            dismissSettingsBeforeOpening: !embedded,
          ),
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

class _SpokenVoiceSetting extends StatefulWidget {
  const _SpokenVoiceSetting({required this.controller});

  final SpokenGuidanceController controller;

  @override
  State<_SpokenVoiceSetting> createState() => _SpokenVoiceSettingState();
}

class _SpokenVoiceSettingState extends State<_SpokenVoiceSetting> {
  static const _systemDefaultKey = '__system_default__';
  late Future<List<SpokenGuidanceVoice>> _voices;

  @override
  void initState() {
    super.initState();
    _voices = widget.controller.availableVoices();
  }

  @override
  void didUpdateWidget(covariant _SpokenVoiceSetting oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _voices = widget.controller.availableVoices();
    }
  }

  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<List<SpokenGuidanceVoice>>(
    future: _voices,
    builder: (context, snapshot) {
      final voices = snapshot.data ?? const <SpokenGuidanceVoice>[];
      return AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final chosen = widget.controller.voice;
          final installed = chosen == null || voices.contains(chosen);
          final selectedKey = installed && chosen != null
              ? chosen.key
              : _systemDefaultKey;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                key: ValueKey('spoken-voice-$selectedKey'),
                initialValue: selectedKey,
                decoration: InputDecoration(
                  labelText: 'Voice',
                  helperText:
                      snapshot.connectionState == ConnectionState.waiting
                      ? 'Loading installed voices…'
                      : !installed
                      ? 'The saved voice is unavailable; using the system default.'
                      : 'Used for directions and safety alerts. Selecting one plays a preview.',
                ),
                items: [
                  const DropdownMenuItem(
                    value: _systemDefaultKey,
                    child: Text('System default'),
                  ),
                  for (final voice in voices)
                    DropdownMenuItem(
                      value: voice.key,
                      child: Text(voice.label, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: snapshot.connectionState == ConnectionState.waiting
                    ? null
                    : (key) => unawaited(
                        widget.controller.setVoiceAndPreview(
                          key == null || key == _systemDefaultKey
                              ? null
                              : voices.firstWhere((voice) => voice.key == key),
                        ),
                      ),
              ),
            ],
          );
        },
      );
    },
  );
}

/// Settings row that both shows the running build and opens the full
/// About & build detail. Two taps from the settings button, and the build
/// number is legible without opening anything.
class _AboutBuildTile extends StatelessWidget {
  const _AboutBuildTile({
    required this.identity,
    required this.dismissSettingsBeforeOpening,
    this.lastRelaySync,
  });

  final BuildIdentity identity;
  final bool dismissSettingsBeforeOpening;
  final DateTime? lastRelaySync;

  @override
  Widget build(BuildContext context) {
    final updateLikely =
        identity.updateStateAt(DateTime.now()) ==
        TesterUpdateState.newerBuildLikely;
    return ListTile(
      key: const Key('open-about-build'),
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        updateLikely ? Icons.system_update_alt : Icons.info_outline,
        color: updateLikely ? const Color(0xFFFFC857) : null,
      ),
      title: const Text('About & build'),
      subtitle: Text(
        updateLikely
            ? '${identity.versionLabel} · a newer tester build is probably available'
            : '${identity.versionLabel} · ${identity.track.label}',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        final appContext = Navigator.of(context, rootNavigator: true).context;
        if (dismissSettingsBeforeOpening) Navigator.of(context).pop();
        unawaited(
          AboutBuildSheet.show(
            appContext,
            identity: identity,
            lastRelaySync: lastRelaySync,
          ),
        );
      },
    );
  }
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

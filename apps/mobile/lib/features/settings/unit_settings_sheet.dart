import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../controllers/distance_unit_controller.dart';
import '../../controllers/global_ride_heatmap_controller.dart';
import '../../controllers/map_style_mode_controller.dart';
import '../../controllers/rider_profile_controller.dart';
import '../../controllers/route_progress_display_controller.dart';
import '../../controllers/speed_limit_display_controller.dart';
import '../../controllers/ride_diagnostics_controller.dart';
import '../../controllers/spoken_guidance_controller.dart';
import '../../controllers/test_control_controller.dart';
import '../map/discovery_layer_toggles.dart';
import '../../domain/completed_ride_store.dart';
import '../../domain/distance_unit.dart';
import '../../domain/map_style_mode.dart';
import '../../domain/rider_color.dart';
import '../../services/basemap_configuration.dart';
import '../../services/build_identity.dart';
import '../../services/natural_voice_pack.dart';
import '../../services/spoken_guidance.dart';
import '../../services/global_ride_heatmap.dart';
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
    this.routeProgressDisplay,
    this.currentRideActive = false,
    this.lastRelaySync,
    this.buildIdentity,
    this.testControl,
    this.spokenGuidance,
    this.rideDiagnostics,
    this.globalRideHeatmap,
    this.completedRideStore,
    this.embedded = false,
  });

  final DistanceUnitController controller;
  final MapStyleModeController mapStyleMode;
  final RiderProfileController riderProfile;
  final SpeedLimitDisplayController speedLimitDisplay;
  final RouteProgressDisplayController? routeProgressDisplay;
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
  final GlobalRideHeatmapController? globalRideHeatmap;
  final CompletedRideStore? completedRideStore;

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
    RouteProgressDisplayController? routeProgressDisplay,
    bool currentRideActive = false,
    DateTime? lastRelaySync,
    BuildIdentity? buildIdentity,
    TestControlController? testControl,
    SpokenGuidanceController? spokenGuidance,
    RideDiagnosticsController? rideDiagnostics,
    GlobalRideHeatmapController? globalRideHeatmap,
    CompletedRideStore? completedRideStore,
  }) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => UnitSettingsSheet(
      controller: controller,
      mapStyleMode: mapStyleMode,
      riderProfile: riderProfile,
      speedLimitDisplay: speedLimitDisplay,
      routeProgressDisplay: routeProgressDisplay,
      currentRideActive: currentRideActive,
      lastRelaySync: lastRelaySync,
      buildIdentity: buildIdentity,
      testControl: testControl,
      spokenGuidance: spokenGuidance,
      rideDiagnostics: rideDiagnostics,
      globalRideHeatmap: globalRideHeatmap,
      completedRideStore: completedRideStore,
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      controller,
      mapStyleMode,
      speedLimitDisplay,
      ?routeProgressDisplay,
      ?globalRideHeatmap,
    ]),
    builder: (context, _) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Settings', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 20),
          // Near the top, and here rather than only on the map's overflow
          // menu, because that menu does not exist during a ride: `hideChrome`
          // removes the whole app bar once the navigation canvas is up, so
          // there was no way to change a layer mid-ride at all (#593).
          Text(
            'MAP LAYERS',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: const Color(0xFF8D98A7),
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          ListTile(
            key: const Key('open-discovery-layers'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.layers_outlined),
            title: const Text('Café and road layers'),
            subtitle: const Text('Which optional layers appear on the map'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              final appContext = Navigator.of(
                context,
                rootNavigator: true,
              ).context;
              if (!embedded) Navigator.of(context).pop();
              unawaited(DiscoveryLayersScreen.show(appContext));
            },
          ),
          const SizedBox(height: 16),
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
            controller.followsAutomatic
                ? controller.roadJurisdiction == null
                      ? 'Automatic: using the device locale default '
                            '(${controller.localeDefault.label.toLowerCase()}) until your road country is known.'
                      : 'Automatic for ${controller.roadJurisdiction!.name}: '
                            '${controller.automaticDefault.label.toLowerCase()}.'
                : 'Manual override. Automatic is '
                      '${controller.automaticDefault.label.toLowerCase()}'
                      '${controller.roadJurisdiction == null ? ' from the device locale' : ' for ${controller.roadJurisdiction!.name}'}.',
            style: const TextStyle(color: Color(0xFF98A3B1)),
          ),
          if (!controller.followsAutomatic) ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                key: const Key('use-locale-distance-unit'),
                onPressed: () => unawaited(controller.useAutomaticDefault()),
                child: const Text('Use automatic units'),
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
              'roads in France, Great Britain and the Isle of Man using '
              '© OpenStreetMap contributors via Valhalla. French signs are '
              'shown in km/h and British signs in mph. Mapped limits are not '
              'live; roadside signs always apply. Turning this off is remembered.',
            ),
          ),
          if (routeProgressDisplay case final progressDisplay?) ...[
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              key: const Key('route-progress-display-toggle'),
              contentPadding: EdgeInsets.zero,
              value: progressDisplay.enabled,
              onChanged: progressDisplay.setEnabled,
              title: const Text('Show route time and distance'),
              subtitle: const Text(
                'Shows the current time, total distance and estimated time '
                'remaining, plus the next named stop and its ETA. Estimates '
                'use your recent riding speed and stay blank until you move.',
              ),
            ),
          ],
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
          if (globalRideHeatmap case final heatmap?) ...[
            Text(
              'GLOBAL RIDES',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: const Color(0xFF8D98A7),
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<HeatmapContributionConsent>(
              key: const Key('global-heatmap-consent'),
              initialValue: heatmap.consent,
              decoration: const InputDecoration(
                labelText: 'Contribute completed rides',
              ),
              items: const [
                DropdownMenuItem(
                  value: HeatmapContributionConsent.never,
                  child: Text('Never'),
                ),
                DropdownMenuItem(
                  value: HeatmapContributionConsent.askAfterEachRide,
                  child: Text('Ask after each ride'),
                ),
                DropdownMenuItem(
                  value: HeatmapContributionConsent.always,
                  child: Text('Always after a ride'),
                ),
              ],
              onChanged: (value) async {
                if (value == null || value == heatmap.consent) return;
                if (value != HeatmapContributionConsent.never &&
                    !await _confirmHeatmapContribution(context, heatmap)) {
                  return;
                }
                await heatmap.setConsent(value);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              key: const Key('global-heatmap-trim'),
              initialValue: heatmap.trimMeters,
              decoration: const InputDecoration(labelText: 'Hide at each end'),
              items: const [
                DropdownMenuItem(value: 0, child: Text('Nothing')),
                DropdownMenuItem(value: 500, child: Text('500 m')),
                DropdownMenuItem(
                  value: 1000,
                  child: Text('1 km (recommended)'),
                ),
                DropdownMenuItem(value: 2000, child: Text('2 km')),
              ],
              onChanged: heatmap.consent == HeatmapContributionConsent.never
                  ? null
                  : (value) {
                      if (value != null) {
                        unawaited(heatmap.setTrimMeters(value));
                      }
                    },
            ),
            const SizedBox(height: 10),
            const Text(
              'The phone removes both ends, converts the travelled track to an '
              'unordered set of coarse cells, and sends no ride name, route '
              'order, time, speed, rider identity or ride code. Public cells '
              'appear only after at least three contributors. Viewing the map '
              'layer never opts you in.',
              style: TextStyle(color: Color(0xFF98A3B1), height: 1.4),
            ),
            if (heatmap.consent != HeatmapContributionConsent.never) ...[
              const SizedBox(height: 8),
              if (completedRideStore case final rides?)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const Key('global-heatmap-share-history'),
                    onPressed: heatmap.sharingHistory
                        ? null
                        : () => unawaited(
                            _shareHeatmapHistory(context, heatmap, rides),
                          ),
                    icon: heatmap.sharingHistory
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.cloud_upload_outlined),
                    label: Text(
                      heatmap.sharingHistory
                          ? 'Sharing saved coverage…'
                          : 'Share existing ride history',
                    ),
                  ),
                ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('global-heatmap-remove-data'),
                  onPressed: () =>
                      unawaited(_removeHeatmapContributions(context, heatmap)),
                  icon: const Icon(Icons.delete_sweep_outlined),
                  label: const Text('Stop contributing and remove my data'),
                ),
              ),
            ],
            const SizedBox(height: 22),
          ],
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
                _NaturalVoicePackSetting(controller: spoken),
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'PHONE VOICE FALLBACK',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: const Color(0xFF8D98A7),
                      letterSpacing: 1.1,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
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

  static Future<bool> _confirmHeatmapContribution(
    BuildContext context,
    GlobalRideHeatmapController controller,
  ) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Contribute road coverage?'),
          content: Text(
            'Only travelled coverage cells are sent after a ride. The first '
            'and last ${_trimLabel(controller.trimMeters)} are removed on this '
            'phone. A monthly opaque contributor record is retained for up to '
            '24 months; it is not anonymous and can still describe familiar '
            'areas. You can remove all of it here while this phone retains its '
            'heatmap credential.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Not now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('I understand'),
            ),
          ],
        ),
      ) ??
      false;

  static Future<void> _shareHeatmapHistory(
    BuildContext context,
    GlobalRideHeatmapController controller,
    CompletedRideStore store,
  ) async {
    final rides = await store.list();
    if (!context.mounted) return;
    if (rides.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('There are no saved rides to share yet.')),
      );
      return;
    }
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Share saved ride coverage?'),
            content: Text(
              'This combines coverage from ${rides.length} saved '
              '${rides.length == 1 ? 'ride' : 'rides'} into one unordered '
              'upload. Each ride is trimmed separately first, so the upload '
              'does not join one ride to the next. No ride names, times, '
              'speeds, route order, rider identity or ride codes are sent.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('confirm-global-heatmap-share-history'),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Share coverage'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !context.mounted) return;
    try {
      final result = await controller.contributeHistory(rides);
      if (!context.mounted) return;
      final message = result.shared
          ? 'Shared coverage from ${result.rideCount} saved '
                '${result.rideCount == 1 ? 'ride' : 'rides'}. Public coverage '
                'updates after the next snapshot and still requires three contributors.'
          : 'All eligible saved rides have already been shared.';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not share saved coverage. Your rides remain on this phone.',
          ),
        ),
      );
    }
  }

  static Future<void> _removeHeatmapContributions(
    BuildContext context,
    GlobalRideHeatmapController controller,
  ) async {
    try {
      await controller.stopAndRemoveContributions();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Contribution stopped. Public removal updates with the next daily snapshot.',
          ),
        ),
      );
    } on Object {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not remove heatmap data. Try again when online.',
          ),
        ),
      );
    }
  }

  static String _trimLabel(int meters) => switch (meters) {
    0 => '0 m',
    500 => '500 m',
    1000 => '1 km',
    2000 => '2 km',
    _ => '$meters m',
  };
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
  bool _showAllVoices = false;

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

  void _refreshVoices() {
    setState(() {
      _voices = widget.controller.availableVoices();
    });
  }

  Future<void> _showIosVoiceInstallationHelp() => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Add a more natural iPhone voice'),
      content: const Text(
        'Tail End Charlie can use Enhanced and Premium Apple speech voices '
        'after they are downloaded.\n\n'
        '1. Open iPhone Settings.\n'
        '2. Go to Accessibility → Read & Speak → Voices.\n'
        '3. Choose English → British English, then download an Enhanced or '
        'Premium named voice.\n'
        '4. Return here and tap Refresh installed voices.\n\n'
        'A Siri Voice choice can remain reserved for Siri or VoiceOver and may '
        'not appear in third-party apps. The Natural voice pack above does not '
        'have that limitation.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Done'),
        ),
      ],
    ),
  );

  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<List<SpokenGuidanceVoice>>(
    future: _voices,
    builder: (context, snapshot) {
      final isIos = Theme.of(context).platform == TargetPlatform.iOS;
      final voices = snapshot.data ?? const <SpokenGuidanceVoice>[];
      final highQualityVoiceCount = voices
          .where((voice) => voice.isHighQuality)
          .length;
      return AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final chosen = widget.controller.voice;
          final installedVoice = chosen == null
              ? null
              : _installedMatch(chosen, voices);
          final installed = chosen == null || installedVoice != null;
          final selectedKey = installedVoice?.key ?? _systemDefaultKey;
          final recommended = voices
              .where((voice) => voice.isRecommended)
              .toList(growable: false);
          final visibleVoices =
              (_showAllVoices || recommended.isEmpty
                    ? List<SpokenGuidanceVoice>.of(voices)
                    : <SpokenGuidanceVoice>{
                        ...recommended,
                        ?installedVoice,
                      }.toList())
                ..sort(compareSpokenGuidanceVoices);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                key: ValueKey('spoken-voice-$selectedKey'),
                initialValue: selectedKey,
                decoration: InputDecoration(
                  labelText: 'Fallback/system voice',
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
                  for (final voice in visibleVoices)
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
              const SizedBox(height: 6),
              Text(
                highQualityVoiceCount == 0
                    ? isIos
                          ? 'No Enhanced or Premium voices are installed. Only '
                                'voices installed on this iPhone appear here.'
                          : 'No high-quality offline voices were reported by '
                                'this device. Only voices installed by the '
                                'system speech engine appear here.'
                    : '$highQualityVoiceCount '
                          '${isIos ? 'Enhanced or Premium' : 'high-quality'} '
                          '${highQualityVoiceCount == 1 ? 'voice' : 'voices'} '
                          'installed.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 4,
                  children: [
                    TextButton.icon(
                      key: const Key('refresh-spoken-voices'),
                      onPressed:
                          snapshot.connectionState == ConnectionState.waiting
                          ? null
                          : _refreshVoices,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh installed voices'),
                    ),
                    if (isIos)
                      TextButton.icon(
                        key: const Key('add-natural-ios-voice-help'),
                        onPressed: _showIosVoiceInstallationHelp,
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('How to add natural voices'),
                      ),
                  ],
                ),
              ),
              if (!_showAllVoices && visibleVoices.length < voices.length)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('show-all-spoken-voices'),
                    onPressed: () => setState(() => _showAllVoices = true),
                    child: Text(
                      'Show all ${voices.length} installed English voices',
                    ),
                  ),
                ),
            ],
          );
        },
      );
    },
  );

  SpokenGuidanceVoice? _installedMatch(
    SpokenGuidanceVoice chosen,
    List<SpokenGuidanceVoice> installed,
  ) {
    for (final voice in installed) {
      if (voice == chosen || voice.hasSameNameAndLocale(chosen)) return voice;
    }
    return null;
  }
}

class _NaturalVoicePackSetting extends StatelessWidget {
  const _NaturalVoicePackSetting({required this.controller});

  final SpokenGuidanceController controller;

  @override
  Widget build(BuildContext context) {
    final pack = controller.naturalVoicePack;
    return AnimatedBuilder(
      animation: pack,
      builder: (context, _) => Material(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.graphic_eq),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Natural offline voice · Beta',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (pack.installed)
                    const Chip(
                      visualDensity: VisualDensity.compact,
                      label: Text('Installed'),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                'A more expressive British voice generated on this phone for '
                'complete directions, road names and rider alerts. The same '
                'voice works on iPhone and Android without a connection.',
              ),
              const SizedBox(height: 8),
              if (pack.downloading) ...[
                LinearProgressIndicator(value: pack.downloadProgress),
                const SizedBox(height: 8),
                Text(
                  pack.downloadProgress == null
                      ? 'Downloading natural voice…'
                      : pack.downloadProgress! >= 1
                      ? 'Installing natural voice…'
                      : 'Downloading natural voice · '
                            '${(pack.downloadProgress! * 100).round()}%',
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const Key('cancel-natural-voice-download'),
                    onPressed: pack.cancelInstall,
                    child: const Text('Cancel'),
                  ),
                ),
              ] else if (!pack.installed) ...[
                if (pack.failure case final failure?) ...[
                  Text(
                    failure,
                    key: const Key('natural-voice-install-failure'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    key: const Key('install-natural-voice'),
                    onPressed: controller.installNaturalVoiceAndPreview,
                    icon: const Icon(Icons.download),
                    label: const Text('Download natural voice · 103 MB'),
                  ),
                ),
              ] else ...[
                SwitchListTile.adaptive(
                  key: const Key('natural-voice-toggle'),
                  contentPadding: EdgeInsets.zero,
                  value: pack.enabled,
                  onChanged: pack.setEnabled,
                  title: const Text('Use natural voice'),
                  subtitle: const Text(
                    'A prepared voice gets up to 2.5 seconds to generate a new '
                    'road or rider name. The phone voice remains the fail-safe.',
                  ),
                ),
                DropdownButtonFormField<NaturalNavigationVoice>(
                  key: ValueKey('natural-voice-${pack.voice.name}'),
                  initialValue: pack.voice,
                  decoration: const InputDecoration(labelText: 'Natural voice'),
                  items: [
                    for (final voice in NaturalNavigationVoice.values)
                      DropdownMenuItem(
                        value: voice,
                        child: Text(
                          voice.label,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (voice) {
                    if (voice != null) {
                      unawaited(controller.setNaturalVoiceAndPreview(voice));
                    }
                  },
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 4,
                  children: [
                    TextButton.icon(
                      key: const Key('preview-natural-voice'),
                      onPressed: controller.previewNaturalVoice,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Preview'),
                    ),
                    TextButton.icon(
                      key: const Key('remove-natural-voice'),
                      onPressed: () => _confirmRemove(context, pack),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Remove download'),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 4),
              const Text(
                'Kokoro English v0.19 via Sherpa-ONNX · Apache 2.0. About '
                '153 MB installed. Audio and text stay on this device.',
                style: TextStyle(fontSize: 11, color: Color(0xFF98A3B1)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    NaturalVoicePackController pack,
  ) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove natural voice?'),
        content: const Text(
          'This frees about 153 MB. Navigation will continue with the selected '
          'phone voice, and the natural voice can be downloaded again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (remove == true) await pack.remove();
  }
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

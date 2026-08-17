import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/discovery_layer_preferences.dart';
import '../../services/motorcycle_discovery.dart';
import 'sheet_close_button.dart';

/// Which optional map layers are drawn.
///
/// Shared between the map's overflow menu and Settings, because the map's menu
/// is not reachable everywhere a rider wants this. During a ride `hideChrome`
/// removes the whole app bar, so there was no way to change a layer mid-ride at
/// all; Settings is reachable in free roam, before a ride and during one
/// (#593).
///
/// One widget rather than two matching lists, so the two entry points cannot
/// disagree about what a layer is called or which are on.
class DiscoveryLayerToggles extends StatefulWidget {
  const DiscoveryLayerToggles({
    super.key,
    required this.preferences,
    this.failures = const [],
    this.onChanged,
  });

  /// Null while still loading, or when loading failed — see [failures]. The
  /// toggles are disabled rather than silently doing nothing, which is what
  /// they used to do (#596).
  final DiscoveryLayerPreferences? preferences;

  /// What could not be loaded, named, so a control that cannot work says why.
  final List<String> failures;

  /// Called after a change is persisted, so a host holding a map can redraw.
  final VoidCallback? onChanged;

  @override
  State<DiscoveryLayerToggles> createState() => _DiscoveryLayerTogglesState();
}

class _DiscoveryLayerTogglesState extends State<DiscoveryLayerToggles> {
  static Color _colour(MotorcycleDiscoveryCategory category) =>
      switch (category) {
        MotorcycleDiscoveryCategory.twistyHighlight => const Color(0xFFF97316),
        MotorcycleDiscoveryCategory.mountainPass => const Color(0xFF0F9D8A),
        MotorcycleDiscoveryCategory.goodBikingRoad => const Color(0xFF2583E9),
      };

  @override
  Widget build(BuildContext context) {
    final preferences = widget.preferences;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.failures.isNotEmpty)
          Container(
            key: const Key('discovery-layer-load-failure'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF3A2A22),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              widget.failures.length == 1
                  ? 'Could not load ${widget.failures.single}. Everything else '
                        'here still works.'
                  : 'Could not load ${widget.failures.join(', ')}.',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        CheckboxListTile(
          key: const Key('biker-cafes-layer-toggle'),
          value: preferences?.bikerCafesVisible ?? false,
          secondary: const Icon(Icons.local_cafe, color: Color(0xFFFFC857)),
          title: const Text('Biker cafés'),
          contentPadding: EdgeInsets.zero,
          onChanged: preferences == null
              ? null
              : (enabled) async {
                  await preferences.setBikerCafesVisible(enabled ?? false);
                  if (!mounted) return;
                  setState(() {});
                  widget.onChanged?.call();
                },
        ),
        for (final category in MotorcycleDiscoveryCategory.values)
          CheckboxListTile(
            key: Key('discovery-layer-${category.apiValue}'),
            value: preferences?.categories.contains(category) ?? false,
            secondary: Icon(
              category == MotorcycleDiscoveryCategory.mountainPass
                  ? Icons.terrain
                  : Icons.route,
              color: _colour(category),
            ),
            title: Text(category.label),
            contentPadding: EdgeInsets.zero,
            onChanged: preferences == null
                ? null
                : (enabled) async {
                    await preferences.setCategory(category, enabled ?? false);
                    if (!mounted) return;
                    setState(() {});
                    widget.onChanged?.call();
                  },
          ),
      ],
    );
  }
}

/// The layer controls on their own, for a host with no map of its own to
/// redraw — Settings.
class DiscoveryLayersScreen extends StatefulWidget {
  const DiscoveryLayersScreen({super.key, this.load});

  /// Supplied by tests. Production reads the persisted choices.
  final Future<DiscoveryLayerPreferences> Function()? load;

  static Future<void> show(
    BuildContext context, {
    Future<DiscoveryLayerPreferences> Function()? load,
  }) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => DiscoveryLayersScreen(load: load),
  );

  @override
  State<DiscoveryLayersScreen> createState() => _DiscoveryLayersScreenState();
}

class _DiscoveryLayersScreenState extends State<DiscoveryLayersScreen> {
  DiscoveryLayerPreferences? _preferences;
  List<String> _failures = const [];
  var _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final preferences =
          await (widget.load ?? DiscoveryLayerPreferences.load)();
      if (!mounted) return;
      setState(() {
        _preferences = preferences;
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _failures = const ['the saved layer choices'];
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Map layers',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const SheetCloseButton(),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Choose which optional café and road layers appear on the map. '
            'Choices are remembered on this phone and apply everywhere the map '
            'is shown.',
          ),
          const SizedBox(height: 8),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            Flexible(
              child: SingleChildScrollView(
                child: DiscoveryLayerToggles(
                  preferences: _preferences,
                  failures: _failures,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

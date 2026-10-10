/// The fuel preference in Settings (#951).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/fuel_preference.dart';

/// The Settings row. Loads the app's shared preference itself, so it needs no
/// plumbing from the app's root and cannot disagree with the map.
class FuelPreferenceTile extends StatefulWidget {
  const FuelPreferenceTile({super.key, this.controller});

  /// For tests. The app uses [FuelPreferenceController.shared].
  final FuelPreferenceController? controller;

  @override
  State<FuelPreferenceTile> createState() => _FuelPreferenceTileState();
}

class _FuelPreferenceTileState extends State<FuelPreferenceTile> {
  FuelPreferenceController? _controller;

  @override
  void initState() {
    super.initState();
    if (widget.controller case final controller?) {
      _controller = controller;
    } else {
      unawaited(
        FuelPreferenceController.shared().then(
          (controller) {
            if (mounted) setState(() => _controller = controller);
          },
          // Without stored preferences the row stays as a plain label.
          onError: (Object _) {},
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.local_gas_station_outlined),
        title: Text('Fuel'),
      );
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListTile(
        key: const Key('fuel-preference-tile'),
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          controller.value.isElectric
              ? Icons.ev_station_outlined
              : Icons.local_gas_station_outlined,
        ),
        title: const Text('Fuel'),
        subtitle: Text(
          '${controller.value.summary}. Used by ${controller.value.searchLabel} '
          'and for the prices shown on the map.',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => unawaited(FuelPreferenceSheet.show(context, controller)),
      ),
    );
  }
}

class FuelPreferenceSheet extends StatefulWidget {
  const FuelPreferenceSheet({super.key, required this.controller});

  final FuelPreferenceController controller;

  static Future<void> show(
    BuildContext context,
    FuelPreferenceController controller,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => FuelPreferenceSheet(controller: controller),
  );

  @override
  State<FuelPreferenceSheet> createState() => _FuelPreferenceSheetState();
}

class _FuelPreferenceSheetState extends State<FuelPreferenceSheet> {
  late FuelPreference _value = widget.controller.value;

  void _choose(FuelPreference value) {
    setState(() => _value = value);
    unawaited(widget.controller.set(value));
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
    child: RadioGroup<FuelKind>(
      groupValue: _value.kind,
      onChanged: (kind) {
        if (kind == null) return;
        _choose(
          FuelPreference(
            kind,
            connectors: kind == FuelKind.electric
                ? _value.connectors
                : const {},
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'What does your bike take?',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          for (final kind in FuelKind.values)
            RadioListTile<FuelKind>(
              key: Key('fuel-preference-${kind.apiValue}'),
              value: kind,
              title: Text(kind.label),
            ),
          if (_value.isElectric) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Connectors your bike can use. Leave all off to be shown '
                'every charger.',
              ),
            ),
            for (final connector in ChargerConnector.values)
              CheckboxListTile(
                key: Key('fuel-preference-connector-${connector.name}'),
                value: _value.connectors.contains(connector),
                title: Text(connector.label),
                onChanged: (selected) => _choose(
                  FuelPreference(
                    FuelKind.electric,
                    connectors: {
                      ..._value.connectors.where((c) => c != connector),
                      if (selected == true) connector,
                    },
                  ),
                ),
              ),
          ],
        ],
      ),
    ),
  );
}

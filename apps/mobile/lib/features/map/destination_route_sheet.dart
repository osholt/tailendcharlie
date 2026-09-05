import 'package:flutter/material.dart';

import '../../domain/route_preferences.dart';
import '../../services/navigation_export.dart';

class DestinationPlanRequest {
  const DestinationPlanRequest({
    required this.query,
    this.startQuery,
    this.stopQueries = const [],
    this.handoffTarget,
    this.preferences = RoutePreferences.defaults,
  });

  final String query;

  /// A place/postcode/lat-lng to start from instead of the rider's current
  /// location - e.g. planning a ride from a meeting point before setting off.
  /// Null or blank means "use my current location", same as before this
  /// field existed.
  final String? startQuery;
  final List<String> stopQueries;
  final NavigationTarget? handoffTarget;

  /// The route character asked for, using the same preferences as the web
  /// planner so the two agree about what a route with them means.
  final RoutePreferences preferences;
}

class DestinationRouteSheet extends StatefulWidget {
  const DestinationRouteSheet({super.key, this.initialRequest});

  final DestinationPlanRequest? initialRequest;

  static Future<DestinationPlanRequest?> show(
    BuildContext context, {
    DestinationPlanRequest? initialRequest,
  }) => showModalBottomSheet<DestinationPlanRequest>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => DestinationRouteSheet(initialRequest: initialRequest),
  );

  @override
  State<DestinationRouteSheet> createState() => _DestinationRouteSheetState();
}

class _DestinationRouteSheetState extends State<DestinationRouteSheet> {
  late final TextEditingController _startController;
  late final TextEditingController _destinationController;
  final List<TextEditingController> _stopControllers = [];
  late _DestinationHandoff _handoff;
  late RoutePreferences _preferences;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialRequest;
    _startController = TextEditingController(text: initial?.startQuery ?? '');
    _destinationController = TextEditingController(text: initial?.query ?? '');
    _stopControllers.addAll(
      initial?.stopQueries.map((value) => TextEditingController(text: value)) ??
          const <TextEditingController>[],
    );
    _handoff = _handoffFromTarget(initial?.handoffTarget);
    _preferences = initial?.preferences ?? RoutePreferences.defaults;
  }

  @override
  void dispose() {
    _startController.dispose();
    _destinationController.dispose();
    for (final controller in _stopControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Where are you going?',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            const Text(
              'Enter a place, postcode, or latitude and longitude. Tail End Charlie '
              'will generate a road-following GPX route from your location.',
              style: TextStyle(color: Color(0xFF98A3B1)),
            ),
            const SizedBox(height: 18),
            TextField(
              key: const Key('start-field'),
              controller: _startController,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Start location (optional)',
                hintText: 'Leave blank to use your current location',
                prefixIcon: Icon(Icons.trip_origin),
              ),
            ),
            const SizedBox(height: 14),
            for (var index = 0; index < _stopControllers.length; index++) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: Key('route-stop-field-$index'),
                      controller: _stopControllers[index],
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: 'Stop ${index + 1}',
                        hintText: 'Place, postcode, or coordinates',
                        prefixIcon: const Icon(Icons.add_location_alt_outlined),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Column(
                    children: [
                      IconButton(
                        key: Key('move-route-stop-up-$index'),
                        tooltip: 'Move stop earlier',
                        onPressed: index == 0
                            ? null
                            : () => _moveStop(index, index - 1),
                        icon: const Icon(Icons.arrow_upward),
                      ),
                      IconButton(
                        key: Key('move-route-stop-down-$index'),
                        tooltip: 'Move stop later',
                        onPressed: index == _stopControllers.length - 1
                            ? null
                            : () => _moveStop(index, index + 1),
                        icon: const Icon(Icons.arrow_downward),
                      ),
                      IconButton(
                        key: Key('remove-route-stop-$index'),
                        tooltip: 'Remove stop',
                        onPressed: () => _removeStop(index),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
            OutlinedButton.icon(
              key: const Key('add-route-stop'),
              onPressed: _stopControllers.length >= 8 ? null : _addStop,
              icon: const Icon(Icons.add),
              label: const Text('Add an intermediate stop'),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('destination-field'),
              controller: _destinationController,
              autofocus: widget.initialRequest == null,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Destination',
                hintText: 'e.g. Matlock Bath or 53.12, -1.56',
                errorText: _error,
                prefixIcon: const Icon(Icons.place_outlined),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Route preferences',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            const Text(
              'The same preferences as the web planner, so a route planned '
              'here and one planned on the website mean the same thing.',
              style: TextStyle(color: Color(0xFF98A3B1), fontSize: 12),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<RouteStyle>(
              key: const Key('route-style-field'),
              initialValue: _preferences.style,
              decoration: const InputDecoration(labelText: 'Routing style'),
              items: RouteStyle.values
                  .map(
                    (style) => DropdownMenuItem(
                      value: style,
                      child: Text(style.label),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) => setState(
                () => _preferences = _preferences.copyWith(style: value),
              ),
            ),
            SwitchListTile(
              key: const Key('avoid-motorways-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Avoid motorways'),
              value: _preferences.avoidMotorways,
              onChanged: (value) => setState(
                () =>
                    _preferences = _preferences.copyWith(avoidMotorways: value),
              ),
            ),
            SwitchListTile(
              key: const Key('avoid-major-roads-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Avoid major roads'),
              subtitle: const Text('The quieter-road option.'),
              value: _preferences.avoidMajorRoads,
              onChanged: (value) => setState(
                () => _preferences = _preferences.copyWith(
                  avoidMajorRoads: value,
                ),
              ),
            ),
            SwitchListTile(
              key: const Key('avoid-tolls-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Avoid toll roads'),
              value: _preferences.avoidTolls,
              onChanged: (value) => setState(
                () => _preferences = _preferences.copyWith(avoidTolls: value),
              ),
            ),
            SwitchListTile(
              key: const Key('avoid-ferries-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Avoid ferries'),
              value: _preferences.avoidFerries,
              onChanged: (value) => setState(
                () => _preferences = _preferences.copyWith(avoidFerries: value),
              ),
            ),
            SwitchListTile(
              key: const Key('avoid-unsurfaced-byways-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Avoid unsurfaced byways'),
              subtitle: const Text(
                'On by default. A byway open to all traffic is legal to ride '
                'but often unsurfaced. Turn this off to allow ways '
                'OpenStreetMap tags as unsurfaced or as a track.',
              ),
              value: _preferences.bywaySurface.avoidsUnsurfaced,
              onChanged: (value) => setState(
                () => _preferences = _preferences.copyWith(
                  bywaySurface: value
                      ? BywaySurfacePreference.avoidUnsurfaced
                      : BywaySurfacePreference.allowUnsurfaced,
                ),
              ),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<_DestinationHandoff>(
              key: const Key('destination-handoff-field'),
              initialValue: _handoff,
              decoration: const InputDecoration(labelText: 'Open route with'),
              items: _DestinationHandoff.values
                  .map(
                    (handoff) => DropdownMenuItem(
                      value: handoff,
                      child: Text(handoff.label),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) =>
                  setState(() => _handoff = value ?? _handoff),
            ),
            const SizedBox(height: 8),
            Text(
              _handoff.detail,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF98A3B1)),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('plan-destination-button'),
              onPressed: _submit,
              icon: const Icon(Icons.alt_route),
              label: const Text('Plan road route'),
            ),
          ],
        ),
      ),
    ),
  );

  void _submit() {
    final query = _destinationController.text.trim();
    if (query.isEmpty) {
      setState(() => _error = 'Enter a destination.');
      return;
    }
    Navigator.pop(
      context,
      DestinationPlanRequest(
        query: query,
        startQuery: _startController.text.trim().isEmpty
            ? null
            : _startController.text.trim(),
        stopQueries: _stopControllers
            .map((controller) => controller.text.trim())
            .where((value) => value.isNotEmpty)
            .toList(growable: false),
        handoffTarget: _handoff.target,
        preferences: _preferences,
      ),
    );
  }

  void _addStop() {
    setState(() => _stopControllers.add(TextEditingController()));
  }

  void _removeStop(int index) {
    final removed = _stopControllers.removeAt(index);
    removed.dispose();
    setState(() {});
  }

  void _moveStop(int from, int to) {
    final controller = _stopControllers.removeAt(from);
    _stopControllers.insert(to, controller);
    setState(() {});
  }
}

enum _DestinationHandoff { rideRelay, calimoto, myRouteApp, googleMaps }

_DestinationHandoff _handoffFromTarget(NavigationTarget? target) =>
    switch (target) {
      NavigationTarget.calimoto => _DestinationHandoff.calimoto,
      NavigationTarget.myRouteApp => _DestinationHandoff.myRouteApp,
      NavigationTarget.googleMaps => _DestinationHandoff.googleMaps,
      _ => _DestinationHandoff.rideRelay,
    };

extension on _DestinationHandoff {
  String get label => switch (this) {
    _DestinationHandoff.rideRelay => 'Tail End Charlie',
    _DestinationHandoff.calimoto => 'Calimoto',
    _DestinationHandoff.myRouteApp => 'MyRoute-app',
    _DestinationHandoff.googleMaps => 'Google Maps',
  };

  String get detail => switch (this) {
    _DestinationHandoff.rideRelay =>
      'Show and save the route in Tail End Charlie.',
    _DestinationHandoff.calimoto =>
      'Generate GPX, then choose Calimoto in the system share sheet.',
    _DestinationHandoff.myRouteApp =>
      'Generate GPX, then choose MyRoute-app in the system share sheet.',
    _DestinationHandoff.googleMaps =>
      'Open a Google Maps route preview after saving it in Tail End Charlie.',
  };

  NavigationTarget? get target => switch (this) {
    _DestinationHandoff.rideRelay => null,
    _DestinationHandoff.calimoto => NavigationTarget.calimoto,
    _DestinationHandoff.myRouteApp => NavigationTarget.myRouteApp,
    _DestinationHandoff.googleMaps => NavigationTarget.googleMaps,
  };
}

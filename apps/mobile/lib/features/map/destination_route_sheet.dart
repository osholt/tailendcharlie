import 'package:flutter/material.dart';

import '../../services/navigation_export.dart';

class DestinationPlanRequest {
  const DestinationPlanRequest({required this.query, this.handoffTarget});

  final String query;
  final NavigationTarget? handoffTarget;
}

class DestinationRouteSheet extends StatefulWidget {
  const DestinationRouteSheet({super.key});

  static Future<DestinationPlanRequest?> show(BuildContext context) =>
      showModalBottomSheet<DestinationPlanRequest>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => const DestinationRouteSheet(),
      );

  @override
  State<DestinationRouteSheet> createState() => _DestinationRouteSheetState();
}

class _DestinationRouteSheetState extends State<DestinationRouteSheet> {
  final _destinationController = TextEditingController();
  _DestinationHandoff _handoff = _DestinationHandoff.rideRelay;
  String? _error;

  @override
  void dispose() {
    _destinationController.dispose();
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
              key: const Key('destination-field'),
              controller: _destinationController,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Destination',
                hintText: 'e.g. Matlock Bath or 53.12, -1.56',
                errorText: _error,
                prefixIcon: const Icon(Icons.place_outlined),
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
      DestinationPlanRequest(query: query, handoffTarget: _handoff.target),
    );
  }
}

enum _DestinationHandoff { rideRelay, calimoto, myRouteApp, googleMaps }

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

import 'package:flutter/material.dart';

import '../../services/demo_route_loader.dart';

/// Asks which bundled demo route to use (#934).
///
/// Offered wherever a demo starts - the home menu, Ride Lab and the map's
/// "Load demo route" - so the choice reads the same in each. Returns null when
/// the sheet is dismissed, which callers treat as "do nothing", not as the
/// default.
Future<DemoRoute?> showDemoRoutePicker(
  BuildContext context, {
  required DemoRoute current,
}) => showModalBottomSheet<DemoRoute>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (sheetContext) => SafeArea(
    child: ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 12),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Text(
            'Choose a demo route',
            style: Theme.of(sheetContext).textTheme.titleMedium,
          ),
        ),
        for (final route in DemoRoutes.all)
          ListTile(
            key: Key('demo-route-${route.id}'),
            leading: Icon(
              route.id == current.id
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
            ),
            title: Text(route.title),
            subtitle: Text('${route.region}\n${route.summary}'),
            isThreeLine: true,
            selected: route.id == current.id,
            onTap: () => Navigator.of(sheetContext).pop(route),
          ),
      ],
    ),
  ),
);

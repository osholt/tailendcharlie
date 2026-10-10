import 'package:flutter/material.dart';

import '../../domain/ride_coordination_mode.dart';
import '../../domain/ride_plan.dart';

/// The plan's named places, in order, and the controls that change them (#847).
///
/// This is the list Google Maps shows above a route: where from, the stops,
/// where to. Every row is editable and the start says "Your location" until
/// the rider chooses otherwise.
///
/// Shaping points are deliberately absent. They are drawn on the map and live
/// in the route-adjustment chips; a stop list that also listed them would make
/// the rider's drags look like places they meant to visit (#242, #839).
class RidePlanItinerary extends StatelessWidget {
  const RidePlanItinerary({
    super.key,
    required this.plan,
    required this.currentLocationKnown,
    required this.busy,
    required this.onChangeStart,
    required this.onChangeDestination,
    required this.onAddStop,
    required this.onMoveStop,
    required this.onRemoveStop,
    this.lineIsOriginal = false,
  });

  final RidePlan plan;

  /// Whether the route is still exactly as it was imported or recorded, so the
  /// surface says what an edit will do to it before one is made (#892).
  final bool lineIsOriginal;
  final bool currentLocationKnown;

  /// True while a re-plan is in flight. The rows stay readable; the buttons
  /// wait, so two edits cannot race each other to the router.
  final bool busy;
  final VoidCallback onChangeStart;
  final VoidCallback onChangeDestination;
  final VoidCallback onAddStop;
  final void Function(int from, int to) onMoveStop;
  final ValueChanged<int> onRemoveStop;

  @override
  Widget build(BuildContext context) {
    final start = plan.start;
    final destination = plan.destination;
    const muted = TextStyle(color: Color(0xFF98A3B1));
    return Card(
      key: const Key('ride-plan-itinerary'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              key: const Key('ride-plan-start'),
              leading: Icon(
                start is CurrentLocationStart
                    ? Icons.my_location
                    : Icons.trip_origin,
                color: const Color(0xFF68A9FF),
              ),
              title: Text(switch (start) {
                CurrentLocationStart() => 'Your location',
                PlaceStart(:final place) => place.label,
              }),
              subtitle: Text(
                start is CurrentLocationStart && !currentLocationKnown
                    ? 'Start · waiting for your location, or choose a start'
                    : 'Start',
                style: muted,
              ),
              trailing: TextButton(
                key: const Key('ride-plan-change-start'),
                onPressed: busy ? null : onChangeStart,
                child: const Text('Change'),
              ),
            ),
            // Dragged by the handle, as in Google Maps (#891). The list adds
            // "move before / after" to each row's semantics, so a screen
            // reader keeps the reordering the up and down buttons gave it.
            if (plan.stops.isNotEmpty)
              ReorderableListView.builder(
                key: const Key('ride-plan-stops'),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: plan.stops.length,
                onReorderItem: (from, to) {
                  if (to != from) onMoveStop(from, to);
                },
                itemBuilder: (context, index) {
                  final stop = plan.stops[index];
                  return ListTile(
                    key: Key('ride-plan-stop-$index'),
                    leading: CircleAvatar(
                      radius: 13,
                      child: Text(
                        '${index + 1}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    title: Text(stop.label),
                    subtitle: Text('Stop ${index + 1}', style: muted),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: Key('ride-plan-remove-stop-$index'),
                          tooltip: 'Remove stop',
                          visualDensity: VisualDensity.compact,
                          onPressed: busy ? null : () => onRemoveStop(index),
                          icon: const Icon(Icons.close),
                        ),
                        ReorderableDragStartListener(
                          key: Key('ride-plan-drag-stop-$index'),
                          index: index,
                          enabled: !busy && plan.stops.length > 1,
                          child: Tooltip(
                            message: 'Drag to reorder',
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Icon(
                                Icons.drag_handle,
                                color: busy || plan.stops.length < 2
                                    ? const Color(0xFF5C6673)
                                    : null,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ListTile(
              key: const Key('ride-plan-destination'),
              leading: const Icon(Icons.place, color: Color(0xFFFF7A5C)),
              title: Text(destination?.label ?? 'Choose a destination'),
              subtitle: const Text('Destination', style: muted),
              trailing: TextButton(
                key: const Key('ride-plan-change-destination'),
                onPressed: busy ? null : onChangeDestination,
                child: const Text('Change'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('ride-plan-add-stop'),
                  onPressed:
                      busy || plan.stops.length >= RidePlan.maximumSearchedStops
                      ? null
                      : onAddStop,
                  icon: const Icon(Icons.add_location_alt_outlined),
                  label: const Text('Add stop'),
                ),
              ),
            ),
            if (lineIsOriginal)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Text(
                  'This is the route as it came, kept exactly. Changing the '
                  'start, a stop, the destination, the route options or the '
                  'line re-plans it on roads between the places listed here.',
                  key: Key('ride-plan-original-line-note'),
                  style: TextStyle(color: Color(0xFFFFD89A), fontSize: 12),
                ),
              )
            else if (plan.derivedFromGeometry)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Text(
                  'This route came from a recording or a file. Changing it '
                  're-plans it on roads between the places listed here.',
                  key: Key('ride-plan-derived-note'),
                  style: TextStyle(color: Color(0xFFFFD89A), fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Solo or group, chosen on the plan (#847, #261's modes and wording).
class RidePlanPartySelector extends StatelessWidget {
  const RidePlanPartySelector({
    super.key,
    required this.mode,
    required this.onChanged,
  });

  final RideCoordinationMode mode;
  final ValueChanged<RideCoordinationMode> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('ride-plan-party'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('Who is riding?', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(
            value: false,
            icon: Icon(Icons.person_outline),
            label: Text('Solo'),
          ),
          ButtonSegment(
            value: true,
            icon: Icon(Icons.groups_2_outlined),
            label: Text('Group'),
          ),
        ],
        selected: {mode.isGroup},
        onSelectionChanged: (selection) => onChanged(
          selection.first
              ? (mode.isGroup ? mode : RideCoordinationMode.secondBikeDropOff)
              : RideCoordinationMode.solo,
        ),
      ),
      const SizedBox(height: 6),
      Text(
        mode.isGroup
            ? 'Others join with a code once the ride is created. Choose how '
                  'the group will handle junctions.'
            : 'Navigation for just you. You can ride with others later.',
        style: const TextStyle(color: Color(0xFF98A3B1), fontSize: 13),
      ),
      if (mode.isGroup)
        RadioGroup<RideCoordinationMode>(
          groupValue: mode,
          onChanged: (value) {
            if (value != null) onChanged(value);
          },
          child: Column(
            children: [
              for (final groupMode in const [
                RideCoordinationMode.secondBikeDropOff,
                RideCoordinationMode.keepTogether,
              ])
                RadioListTile<RideCoordinationMode>(
                  key: Key('ride-plan-mode-${groupMode.name}'),
                  contentPadding: EdgeInsets.zero,
                  value: groupMode,
                  title: Text(groupMode.label),
                  subtitle: Text(groupMode.description),
                ),
            ],
          ),
        ),
    ],
  );
}

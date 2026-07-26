import 'package:flutter/material.dart';

import '../../domain/distance_unit.dart';
import '../../domain/imported_route.dart';
import '../../services/measurement_formatter.dart';
import '../../services/navigation_guidance.dart';
import 'maneuver_symbol.dart';

/// Every manoeuvre for the current route, in order.
///
/// The list is built from persisted route data by the same planner that drives
/// the map banner, so it matches what the rider is told at each junction and
/// needs no live routing call.
class ManeuverListScreen extends StatelessWidget {
  const ManeuverListScreen({
    super.key,
    required this.route,
    required this.distanceUnit,
    this.progressMeters,
    this.riderPosition,
    this.planner = const NavigationGuidancePlanner(),
  });

  final ImportedRoute? route;
  final DistanceUnit distanceUnit;

  /// Distance already ridden along the route, used to report how far each
  /// manoeuvre still is. Live guidance supplies its monotonic value.
  final double? progressMeters;

  /// Fallback used to measure rider progress where no tracked value exists.
  final GeoPoint? riderPosition;
  final NavigationGuidancePlanner planner;

  static Future<void> show(
    BuildContext context, {
    required ImportedRoute? route,
    required DistanceUnit distanceUnit,
    double? progressMeters,
    GeoPoint? riderPosition,
  }) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => ManeuverListScreen(
        route: route,
        distanceUnit: distanceUnit,
        progressMeters: progressMeters,
        riderPosition: riderPosition,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final steps = planner.instructions(route);
    final ridden =
        progressMeters ?? planner.progressMetersAt(route, riderPosition);
    final formatter = MeasurementFormatter(distanceUnit);
    return Scaffold(
      appBar: AppBar(
        title: const Text('All turns'),
        bottom: route == null
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(22),
                child: Padding(
                  padding: const EdgeInsets.only(left: 16, bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${steps.length} manoeuvre${steps.length == 1 ? '' : 's'} · '
                      '${route!.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xFFB7C2CF)),
                    ),
                  ),
                ),
              ),
      ),
      body: steps.isEmpty
          ? const Center(
              key: Key('maneuver-list-empty'),
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'This route has no turn instructions saved with it. Recorded '
                  'and imported tracks only carry geometry; plan a destination '
                  'or replace the route to get manoeuvres.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF98A3B1)),
                ),
              ),
            )
          : ListView.separated(
              key: const Key('maneuver-list'),
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: steps.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) => _ManeuverListTile(
                key: Key('maneuver-list-item-$index'),
                position: index + 1,
                step: steps[index],
                formatter: formatter,
                riddenMeters: ridden,
              ),
            ),
    );
  }
}

class _ManeuverListTile extends StatelessWidget {
  const _ManeuverListTile({
    super.key,
    required this.position,
    required this.step,
    required this.formatter,
    required this.riddenMeters,
  });

  final int position;
  final RouteInstructionStep step;
  final MeasurementFormatter formatter;
  final double? riddenMeters;

  @override
  Widget build(BuildContext context) {
    final instruction = step.instruction;
    final ahead = riddenMeters == null
        ? null
        : step.distanceFromStartMeters - riddenMeters!;
    final details = [
      '${formatter.distance(step.distanceFromStartMeters)} from the start',
      if (ahead != null && ahead >= 0) '${formatter.distance(ahead)} ahead',
      if (ahead != null && ahead < 0) 'passed',
      if (instruction.exitNumber case final exit? when exit > 0) 'exit $exit',
    ].join(' · ');
    final showLanes = maneuverLanesAreShowable(instruction.lanes);
    return ListTile(
      isThreeLine: true,
      leading: SizedBox(
        width: 46,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$position',
              style: const TextStyle(
                color: Color(0xFF98A3B1),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 6),
            ManeuverSymbolView(
              instruction: instruction,
              size: 26,
              color: const Color(0xFF68A9FF),
            ),
          ],
        ),
      ),
      title: Text(
        instruction.text,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(details),
          Text(
            instruction.roadLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFFB7C2CF)),
          ),
          if (showLanes) ...[
            const SizedBox(height: 4),
            Text(
              maneuverLaneSummary(instruction.lanes),
              style: const TextStyle(color: Color(0xFF98A3B1), fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

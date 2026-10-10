/// "Navigate to fuel" and "Navigate to charger": the ranked stops, and the
/// rider's choice (#951).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/distance_unit.dart';
import '../../services/fuel_preference.dart';
import '../../services/fuel_prices.dart';
import '../../services/fuel_station_catalogue.dart';
import '../../services/fuel_stop_finder.dart';
import '../../services/fuel_stop_ranking.dart';
import '../../services/measurement_formatter.dart';

/// One line of distance for a candidate: "4.2 mi ahead · 0.6 mi detour", or
/// "3.1 mi away" without a route.
String fuelStopDistanceText(
  FuelStopCandidate candidate,
  MeasurementFormatter formatter,
) {
  if (!candidate.alongRoute) {
    return '${formatter.distance(candidate.reachMetres)} away';
  }
  final ahead = '${formatter.distance(candidate.reachMetres)} ahead';
  // Under a couple of hundred metres there and back is a pull-in, not a
  // detour worth naming.
  if (candidate.detourMetres < 200) return '$ahead · on the route';
  return '$ahead · ${formatter.distance(candidate.detourMetres)} detour';
}

/// What a rider reads about the station's fuel, apart from distance.
String? fuelStopDetailText(
  FuelStopCandidate candidate,
  FuelPreference preference,
  DateTime now,
) {
  final station = candidate.option.station;
  final parts = <String>[
    if (station.kind == FuelStationKind.charging) ...[
      station.chargerSummary,
      'Tariff and availability not shown',
    ] else if (candidate.option.priceText(now) case final price?)
      price
    else if (candidate.compatibility == FuelCompatibility.unrecorded &&
        !preference.kind.commonlyStocked)
      'Grades sold not recorded',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

class FuelStopSheet extends StatefulWidget {
  const FuelStopSheet({
    super.key,
    required this.search,
    required this.distanceUnit,
    required this.actionLabel,
    this.clock,
  });

  final Future<FuelStopSearchResult> search;
  final DistanceUnit distanceUnit;

  /// What choosing one does, in words: "Add as a stop" or "Go there".
  final String actionLabel;
  final DateTime Function()? clock;

  static Future<FuelStopOption?> show(
    BuildContext context, {
    required Future<FuelStopSearchResult> search,
    required DistanceUnit distanceUnit,
    required String actionLabel,
  }) => showModalBottomSheet<FuelStopOption>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => FuelStopSheet(
      search: search,
      distanceUnit: distanceUnit,
      actionLabel: actionLabel,
    ),
  );

  @override
  State<FuelStopSheet> createState() => _FuelStopSheetState();
}

class _FuelStopSheetState extends State<FuelStopSheet> {
  FuelStopSearchResult? _result;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final result = await widget.search;
      if (mounted) setState(() => _result = result);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final theme = Theme.of(context);
    final formatter = MeasurementFormatter(widget.distanceUnit);
    final now = (widget.clock ?? DateTime.now)();
    final electric = result?.preference.isElectric ?? false;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            result == null
                ? 'Finding fuel…'
                : (electric ? 'Chargers' : 'Fuel') +
                      (result.alongRoute
                          ? ' ahead on your route'
                          : ' near you'),
            style: theme.textTheme.titleLarge,
          ),
        ),
        if (result != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              key: const Key('fuel-stop-preference'),
              'For ${result.preference.summary}. Change it in Settings.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (_error != null)
          const Padding(
            key: Key('fuel-stop-error'),
            padding: EdgeInsets.all(16),
            child: Text('Could not read the fuel station map on this phone.'),
          )
        else if (result == null)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else ...[
          if (_priceNote(result) case final note?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                key: const Key('fuel-stop-price-note'),
                note,
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (result.candidates.isEmpty)
            Padding(
              key: const Key('fuel-stop-empty'),
              padding: const EdgeInsets.all(16),
              child: Text(
                result.alongRoute
                    ? 'No ${electric ? 'charger' : 'fuel station'} is mapped '
                          'within 3 km of the next 80 km of your route.'
                    : 'No ${electric ? 'charger' : 'fuel station'} is mapped '
                          'within 25 km of you.',
              ),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final (index, candidate) in result.candidates.indexed)
                  _CandidateTile(
                    key: Key('fuel-stop-candidate-$index'),
                    candidate: candidate,
                    preference: result.preference,
                    formatter: formatter,
                    now: now,
                    actionLabel: widget.actionLabel,
                    onChoose: () => Navigator.of(context).pop(candidate.option),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (result.coverageCaveat.isNotEmpty)
                  Text(result.coverageCaveat, style: theme.textTheme.bodySmall),
                for (final (index, attribution) in result.attributions.indexed)
                  Text(
                    attribution,
                    key: Key('fuel-stop-attribution-$index'),
                    style: theme.textTheme.bodySmall,
                  ),
                for (final (index, url) in result.reportErrorUrls.indexed)
                  TextButton(
                    key: Key('fuel-stop-report-error-$index'),
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                    onPressed: () => unawaited(
                      launchUrl(url, mode: LaunchMode.externalApplication),
                    ),
                    child: const Text('Report a wrong price'),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static String? _priceNote(FuelStopSearchResult result) {
    if (result.preference.isElectric) return null;
    return switch (result.prices) {
      FuelPriceAvailability.available => null,
      // Said once, plainly: prices are simply not switched on yet.
      FuelPriceAvailability.notOffered =>
        'Prices are not available yet. Stations are ranked by distance.',
      FuelPriceAvailability.unavailable =>
        'Prices could not be fetched just now. Stations are ranked by '
            'distance.',
    };
  }
}

class _CandidateTile extends StatelessWidget {
  const _CandidateTile({
    super.key,
    required this.candidate,
    required this.preference,
    required this.formatter,
    required this.now,
    required this.actionLabel,
    required this.onChoose,
  });

  final FuelStopCandidate candidate;
  final FuelPreference preference;
  final MeasurementFormatter formatter;
  final DateTime now;
  final String actionLabel;
  final VoidCallback onChoose;

  @override
  Widget build(BuildContext context) {
    final station = candidate.option.station;
    final freshness = candidate.option.freshness(now);
    final detail = fuelStopDetailText(candidate, preference, now);
    final dim = freshness != null && freshness != FuelPriceFreshness.current;
    return ListTile(
      leading: Icon(
        station.kind == FuelStationKind.charging
            ? Icons.ev_station_outlined
            : Icons.local_gas_station_outlined,
      ),
      title: Text(candidate.option.label),
      subtitle: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: fuelStopDistanceText(candidate, formatter)),
            if (detail != null)
              TextSpan(
                text: '\n$detail',
                style: dim
                    ? TextStyle(color: Theme.of(context).disabledColor)
                    : null,
              ),
          ],
        ),
      ),
      isThreeLine: detail != null,
      trailing: TextButton(onPressed: onChoose, child: Text(actionLabel)),
      onTap: onChoose,
    );
  }
}

/// "Navigate to fuel" or "Navigate to charger" as a button, worded from the
/// rider's saved preference. Loads the shared preference itself so a surface
/// can offer it without plumbing.
class FuelStopButton extends StatefulWidget {
  const FuelStopButton({super.key, required this.onPressed});

  final VoidCallback? onPressed;

  @override
  State<FuelStopButton> createState() => _FuelStopButtonState();
}

class _FuelStopButtonState extends State<FuelStopButton> {
  FuelPreferenceController? _preference;

  @override
  void initState() {
    super.initState();
    unawaited(
      FuelPreferenceController.shared().then((preference) {
        if (mounted) setState(() => _preference = preference);
      }, onError: (Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preference = _preference;
    Widget button(FuelPreference value) => TextButton.icon(
      key: const Key('fuel-stop-button'),
      onPressed: widget.onPressed,
      icon: Icon(
        value.isElectric
            ? Icons.ev_station_outlined
            : Icons.local_gas_station_outlined,
      ),
      label: Text(value.searchLabel),
    );
    if (preference == null) {
      return button(FuelPreferenceController.defaultPreference);
    }
    return ListenableBuilder(
      listenable: preference,
      builder: (context, _) => button(preference.value),
    );
  }
}

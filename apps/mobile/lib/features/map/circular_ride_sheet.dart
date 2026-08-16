import 'package:flutter/material.dart';

import '../../domain/distance_unit.dart';
import '../../domain/imported_route.dart';
import '../../services/circular_ride_planner.dart';

class CircularRideSheet extends StatefulWidget {
  const CircularRideSheet({
    super.key,
    required this.start,
    required this.distanceUnit,
    this.personalHeatmapCells = const [],
    this.globalHeatmapCells = const [],
  });

  final GeoPoint start;
  final DistanceUnit distanceUnit;
  final List<CircularRideHeatCell> personalHeatmapCells;
  final List<CircularRideHeatCell> globalHeatmapCells;

  static Future<CircularRideRequest?> show(
    BuildContext context, {
    required GeoPoint start,
    required DistanceUnit distanceUnit,
    List<CircularRideHeatCell> personalHeatmapCells = const [],
    List<CircularRideHeatCell> globalHeatmapCells = const [],
  }) => showModalBottomSheet<CircularRideRequest>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => CircularRideSheet(
      start: start,
      distanceUnit: distanceUnit,
      personalHeatmapCells: personalHeatmapCells,
      globalHeatmapCells: globalHeatmapCells,
    ),
  );

  @override
  State<CircularRideSheet> createState() => _CircularRideSheetState();
}

class _CircularRideSheetState extends State<CircularRideSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _distanceController;
  CircularRideDirection _direction = CircularRideDirection.north;
  RideDayLength _dayLength = RideDayLength.custom;
  RouteStyle _style = RouteStyle.flowing;
  Duration _fuelEvery = const Duration(hours: 2);
  Duration _comfortEvery = const Duration(minutes: 90);
  Duration _mealAfter = const Duration(hours: 3);
  CircularRideHeatmapPreference _heatmapPreference =
      CircularRideHeatmapPreference.none;
  bool _avoidMotorways = true;
  bool _avoidMajorRoads = false;

  double get _unitMetres =>
      widget.distanceUnit == DistanceUnit.miles ? 1609.344 : 1000;

  @override
  void initState() {
    super.initState();
    _distanceController = TextEditingController(
      text: widget.distanceUnit == DistanceUnit.miles ? '80' : '130',
    );
  }

  @override
  void dispose() {
    _distanceController.dispose();
    super.dispose();
  }

  void _selectDayLength(RideDayLength? value) {
    if (value == null) return;
    setState(() {
      _dayLength = value;
      if (value.duration != null) {
        final metres = dayRideDistanceMeters(value);
        _distanceController.text = (metres / _unitMetres).round().toString();
      }
    });
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final distance =
        double.parse(_distanceController.text.trim()) * _unitMetres;
    Navigator.of(context).pop(
      CircularRideRequest(
        start: widget.start,
        distanceMeters: distance,
        direction: _direction,
        preferences: RoutePreferences(
          style: _style,
          avoidMotorways: _avoidMotorways,
          avoidMajorRoads: _avoidMajorRoads,
        ),
        dayLength: _dayLength,
        fuelEvery: _fuelEvery,
        comfortEvery: _comfortEvery,
        mealAfter: _mealAfter,
        heatmapPreference: _heatmapPreference,
        heatmapCells: switch (_heatmapPreference) {
          CircularRideHeatmapPreference.personal => widget.personalHeatmapCells,
          CircularRideHeatmapPreference.global => widget.globalHeatmapCells,
          CircularRideHeatmapPreference.none => const [],
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Create a circular ride',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            const Text(
              'Choose a general direction and length. You can draw the result '
              'around other roads and add café stops before saving it.',
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<RideDayLength>(
              key: const Key('circular-day-length'),
              initialValue: _dayLength,
              decoration: const InputDecoration(labelText: 'Ride length'),
              items: [
                for (final value in RideDayLength.values)
                  DropdownMenuItem(value: value, child: Text(value.label)),
              ],
              onChanged: _selectDayLength,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('circular-distance'),
              controller: _distanceController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'Approximate total distance',
                suffixText: widget.distanceUnit == DistanceUnit.miles
                    ? 'mi'
                    : 'km',
              ),
              validator: (value) {
                final number = double.tryParse(value?.trim() ?? '');
                if (number == null) return 'Enter a distance.';
                final metres = number * _unitMetres;
                if (metres < 8000 || metres > 800000) {
                  return 'Choose between 8 km and 800 km.';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            Text('Direction', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final direction in CircularRideDirection.values)
                  ChoiceChip(
                    key: Key('circular-direction-${direction.label}'),
                    label: Text(direction.label),
                    selected: _direction == direction,
                    onSelected: (_) => setState(() => _direction = direction),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<RouteStyle>(
              key: const Key('circular-road-style'),
              initialValue: _style,
              decoration: const InputDecoration(labelText: 'Road character'),
              items: [
                for (final style in RouteStyle.values)
                  DropdownMenuItem(
                    value: style,
                    child: Text(
                      style == RouteStyle.quickest ? 'Direct' : style.label,
                    ),
                  ),
              ],
              onChanged: (value) => setState(() => _style = value ?? _style),
            ),
            CheckboxListTile(
              value: _avoidMotorways,
              contentPadding: EdgeInsets.zero,
              title: const Text('Avoid motorways'),
              onChanged: (value) =>
                  setState(() => _avoidMotorways = value ?? false),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<CircularRideHeatmapPreference>(
              key: const Key('circular-heatmap-preference'),
              initialValue: _heatmapPreference,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Road popularity preference',
                helperText: 'A gentle preference, never a required road.',
              ),
              items: [
                const DropdownMenuItem(
                  value: CircularRideHeatmapPreference.none,
                  child: Text('Off'),
                ),
                DropdownMenuItem(
                  value: CircularRideHeatmapPreference.personal,
                  enabled: circularRideHeatmapBiasAvailable(
                    widget.personalHeatmapCells,
                    start: widget.start,
                  ),
                  child: Text(
                    circularRideHeatmapBiasAvailable(
                          widget.personalHeatmapCells,
                          start: widget.start,
                        )
                        ? 'Prefer my ridden roads'
                        : 'My ridden roads · not enough coverage',
                  ),
                ),
                DropdownMenuItem(
                  value: CircularRideHeatmapPreference.global,
                  enabled: circularRideHeatmapBiasAvailable(
                    widget.globalHeatmapCells,
                    start: widget.start,
                  ),
                  child: Text(
                    circularRideHeatmapBiasAvailable(
                          widget.globalHeatmapCells,
                          start: widget.start,
                        )
                        ? 'Prefer popular public roads'
                        : 'Popular public roads · not enough coverage',
                  ),
                ),
              ],
              onChanged: (value) => setState(
                () => _heatmapPreference =
                    value ?? CircularRideHeatmapPreference.none,
              ),
            ),
            CheckboxListTile(
              value: _avoidMajorRoads,
              contentPadding: EdgeInsets.zero,
              title: const Text('Prefer quieter roads'),
              onChanged: (value) =>
                  setState(() => _avoidMajorRoads = value ?? false),
            ),
            if (_dayLength != RideDayLength.custom) ...[
              DropdownButtonFormField<Duration>(
                key: const Key('circular-fuel-frequency'),
                initialValue: _fuelEvery,
                decoration: const InputDecoration(
                  labelText: 'Fuel about every',
                ),
                items: _intervalItems,
                onChanged: (value) =>
                    setState(() => _fuelEvery = value ?? _fuelEvery),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<Duration>(
                key: const Key('circular-comfort-frequency'),
                initialValue: _comfortEvery,
                decoration: const InputDecoration(
                  labelText: 'Bathroom / comfort about every',
                ),
                items: _intervalItems,
                onChanged: (value) =>
                    setState(() => _comfortEvery = value ?? _comfortEvery),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<Duration>(
                key: const Key('circular-meal-time'),
                initialValue: _mealAfter,
                decoration: const InputDecoration(
                  labelText: 'Meal after about',
                  helperText:
                      'A nearby biker café is preferred when available.',
                ),
                items: const [
                  DropdownMenuItem(
                    value: Duration(hours: 2),
                    child: Text('2 hours'),
                  ),
                  DropdownMenuItem(
                    value: Duration(hours: 3),
                    child: Text('3 hours'),
                  ),
                  DropdownMenuItem(
                    value: Duration(hours: 4),
                    child: Text('4 hours'),
                  ),
                  DropdownMenuItem(
                    value: Duration(hours: 5),
                    child: Text('5 hours'),
                  ),
                ],
                onChanged: (value) =>
                    setState(() => _mealAfter = value ?? _mealAfter),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton.icon(
              key: const Key('generate-circular-ride'),
              onPressed: _submit,
              icon: const Icon(Icons.sync),
              label: const Text('Generate ride'),
            ),
          ],
        ),
      ),
    ),
  );

  static const _intervalItems = [
    DropdownMenuItem(value: Duration(hours: 1), child: Text('1 hour')),
    DropdownMenuItem(value: Duration(minutes: 90), child: Text('1½ hours')),
    DropdownMenuItem(value: Duration(hours: 2), child: Text('2 hours')),
    DropdownMenuItem(value: Duration(hours: 3), child: Text('3 hours')),
  ];
}

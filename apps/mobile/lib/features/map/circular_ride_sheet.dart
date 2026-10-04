import 'package:flutter/material.dart';

import '../../domain/distance_unit.dart';
import '../../domain/imported_route.dart';
import '../../domain/ride_plan.dart';
import '../../services/circular_ride_planner.dart';
import '../../services/road_routing.dart';
import 'place_search_sheet.dart';

class CircularRideSheet extends StatefulWidget {
  const CircularRideSheet({
    super.key,
    required this.start,
    required this.distanceUnit,
    this.initialRequest,
    this.personalHeatmapCells = const [],
    this.globalHeatmapCells = const [],
    this.searchService,
  });

  /// The rider's location: where the loop starts and finishes unless the rider
  /// chooses somewhere else. Null while no fix is known, which no longer stops
  /// a loop being planned from a chosen start (#847).
  final GeoPoint? start;
  final DistanceUnit distanceUnit;
  final CircularRideRequest? initialRequest;
  final List<CircularRideHeatCell> personalHeatmapCells;
  final List<CircularRideHeatCell> globalHeatmapCells;

  /// Lets the start be changed with the same submit-only search as the plan
  /// surface. Without it the loop starts where the rider is.
  final DestinationSearchService? searchService;

  static Future<CircularRideRequest?> show(
    BuildContext context, {
    required GeoPoint? start,
    required DistanceUnit distanceUnit,
    CircularRideRequest? initialRequest,
    List<CircularRideHeatCell> personalHeatmapCells = const [],
    List<CircularRideHeatCell> globalHeatmapCells = const [],
    DestinationSearchService? searchService,
  }) => showModalBottomSheet<CircularRideRequest>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => CircularRideSheet(
      start: start,
      distanceUnit: distanceUnit,
      initialRequest: initialRequest,
      personalHeatmapCells: personalHeatmapCells,
      globalHeatmapCells: globalHeatmapCells,
      searchService: searchService,
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

  /// A start the rider chose instead of their location. Null follows them.
  RidePlanPlace? _chosenStart;
  String? _startError;

  GeoPoint? get _start => _chosenStart?.point ?? widget.start;

  double get _unitMetres =>
      widget.distanceUnit == DistanceUnit.miles ? 1609.344 : 1000;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialRequest;
    if (initial != null) {
      // Editing a loop keeps the start it was planned from, which may not be
      // where the rider is any more.
      final current = widget.start;
      if (current == null ||
          current.latitude != initial.start.latitude ||
          current.longitude != initial.start.longitude) {
        _chosenStart = RidePlanPlace(
          point: initial.start,
          label: 'The loop\'s start',
        );
      }
      _direction = initial.direction;
      _dayLength = initial.dayLength;
      _style = initial.preferences.style;
      _fuelEvery = initial.fuelEvery;
      _comfortEvery = initial.comfortEvery;
      _mealAfter = initial.mealAfter;
      _heatmapPreference = initial.heatmapPreference;
      _avoidMotorways = initial.preferences.avoidMotorways;
      _avoidMajorRoads = initial.preferences.avoidMajorRoads;
    }
    final distance = initial?.distanceMeters;
    _distanceController = TextEditingController(
      text: distance == null
          ? widget.distanceUnit == DistanceUnit.miles
                ? '80'
                : '130'
          : _formatDistance(distance / _unitMetres),
    );
  }

  static String _formatDistance(double value) {
    final fixed = value.toStringAsFixed(1);
    return fixed.endsWith('.0') ? fixed.substring(0, fixed.length - 2) : fixed;
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

  Future<void> _changeStart() async {
    final search = widget.searchService;
    if (search == null) return;
    final choice = await PlaceSearchSheet.show(
      context,
      searchService: search,
      title: 'Start and finish at',
      offerCurrentLocation: true,
      currentLocationKnown: widget.start != null,
    );
    if (choice == null || !mounted) return;
    setState(() {
      _chosenStart = switch (choice) {
        PlaceSearchCurrentLocation() => null,
        PlaceSearchPlace(:final place) => place,
      };
      _startError = null;
    });
  }

  void _submit() {
    final start = _start;
    final formValid = _formKey.currentState!.validate();
    if (start == null) {
      setState(
        () => _startError = widget.searchService == null
            ? 'Enable location so the circular ride can start and finish here.'
            : 'Choose where the loop starts, or allow location access.',
      );
      return;
    }
    if (!formValid) return;
    final distance =
        double.parse(_distanceController.text.trim()) * _unitMetres;
    Navigator.of(context).pop(
      CircularRideRequest(
        start: start,
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
            const SizedBox(height: 8),
            ListTile(
              key: const Key('circular-ride-start'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                _chosenStart == null ? Icons.my_location : Icons.trip_origin,
                color: const Color(0xFF68A9FF),
              ),
              title: Text(_chosenStart?.label ?? 'Your location'),
              subtitle: Text(
                _startError ??
                    (_start == null
                        ? 'Waiting for your location, or choose a start'
                        : 'Start and finish'),
                style: TextStyle(
                  color: _startError == null
                      ? const Color(0xFF98A3B1)
                      : Theme.of(context).colorScheme.error,
                ),
              ),
              trailing: widget.searchService == null
                  ? null
                  : TextButton(
                      key: const Key('circular-ride-change-start'),
                      onPressed: _changeStart,
                      child: const Text('Change'),
                    ),
            ),
            const SizedBox(height: 8),
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

import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/ride_controller.dart';
import '../../controllers/rider_profile_controller.dart';
import '../../domain/imported_route.dart';
import '../../domain/ride_coordination_mode.dart';
import 'ride_invite_step.dart';

/// Makes a group ride from what the rider is doing, then hands them its code
/// (#847).
///
/// One sheet for every way into a group ride from the phone: a plan confirmed
/// as a group, and — from the map — riding with others. It carries the route
/// into the ride in the same step that creates it, so the route arrives with
/// the ride rather than being chosen again inside it, and the invitation is
/// on screen before the rider looks for it.
///
/// It is a sheet rather than a screen on purpose. Creating the ride replaces
/// the free-roam map with the ride shell underneath it; a sheet on the root
/// navigator survives that and can still show the code, which is what the
/// ride form has always relied on.
class RideWithOthersSheet extends StatefulWidget {
  const RideWithOthersSheet({
    super.key,
    required this.controller,
    required this.riderProfile,
    this.route,
    this.coordinationMode,
    this.startNow = false,
    this.continuesRideId,
  });

  final RideController controller;
  final RiderProfileController riderProfile;

  /// The route the group ride takes, published as its first revision.
  final ImportedRoute? route;

  /// Already chosen on the plan surface, in which case the ride is created at
  /// once. Null asks here.
  final RideCoordinationMode? coordinationMode;

  /// Starts the ride as it is created, for a rider who is already riding.
  final bool startNow;

  /// The ride this group ride carries on from, filed with it as one (#896).
  final String? continuesRideId;

  static Future<void> show(
    BuildContext context, {
    required RideController controller,
    required RiderProfileController riderProfile,
    ImportedRoute? route,
    RideCoordinationMode? coordinationMode,
    bool startNow = false,
    String? continuesRideId,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => RideWithOthersSheet(
      controller: controller,
      riderProfile: riderProfile,
      route: route,
      coordinationMode: coordinationMode,
      startNow: startNow,
      continuesRideId: continuesRideId,
    ),
  );

  @override
  State<RideWithOthersSheet> createState() => _RideWithOthersSheetState();
}

class _RideWithOthersSheetState extends State<RideWithOthersSheet> {
  late RideCoordinationMode _mode =
      widget.coordinationMode ?? RideCoordinationMode.secondBikeDropOff;
  late final _nameController = TextEditingController(
    text: widget.riderProfile.displayName,
  );

  /// Asked only when onboarding left no name: the roster is how a group finds
  /// each other, and a name the app already knows is not asked again (#431).
  late final bool _needsName = widget.riderProfile.displayName.trim().isEmpty;
  bool _creating = false;
  bool _created = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.coordinationMode != null && !_needsName) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_create());
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_creating || _created) return;
    final controller = widget.controller;
    final profile = widget.riderProfile;
    final name = _needsName ? _nameController.text.trim() : profile.displayName;
    setState(() {
      _creating = true;
      _error = null;
    });
    await controller.startGroupRide(
      displayName: name,
      // `createRide` defaults these rather than reading the profile, so a
      // caller that leaves them out puts the default rider on the map (#600).
      motorcycleStyle: profile.motorcycleStyle,
      riderSymbol: profile.riderSymbol,
      riderColor: profile.riderColor,
      coordinationMode: _mode,
      route: widget.route,
      startNow: widget.startNow,
      continuesRideId: widget.continuesRideId,
    );
    if (!mounted) return;
    // Failure arrives as a message, not an exception: "it returned" is not "it
    // worked", and a button that silently did nothing is worse than a form.
    final created =
        controller.errorMessage == null &&
        controller.hasActiveRide &&
        controller.coordinationMode.isGroup;
    if (created && _needsName) {
      await profile.save(
        displayName: name,
        motorcycleStyle: profile.motorcycleStyle,
        riderSymbol: profile.riderSymbol,
        riderColor: profile.riderColor,
      );
    }
    if (!mounted) return;
    setState(() {
      _creating = false;
      _created = created;
      _error = created
          ? null
          : controller.errorMessage ?? 'The group ride could not be created.';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_created) {
      return RideInviteStep(
        controller: widget.controller,
        onContinue: () => Navigator.of(context).pop(),
      );
    }
    final route = widget.route;
    final explanation = route == null
        ? 'Others join with a code. Choose a route in the ride before you '
              'start.'
        : widget.startNow
        ? 'Your route comes with you and navigation carries on. The ride starts '
              'now, and others join it with a code.'
        : 'Your route comes with you. Others join with a code before you '
              'start.';
    return SingleChildScrollView(
      key: const Key('ride-with-others-sheet'),
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Ride with others',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(explanation, style: const TextStyle(color: Color(0xFFABB5C1))),
          if (route != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.route, size: 18, color: Color(0xFF6ED89A)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    route.name,
                    key: const Key('ride-with-others-route'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ],
          if (widget.coordinationMode == null) ...[
            const SizedBox(height: 12),
            RadioGroup<RideCoordinationMode>(
              groupValue: _mode,
              onChanged: (value) {
                if (value != null && !_creating) setState(() => _mode = value);
              },
              child: Column(
                children: [
                  for (final mode in const [
                    RideCoordinationMode.secondBikeDropOff,
                    RideCoordinationMode.keepTogether,
                  ])
                    RadioListTile<RideCoordinationMode>(
                      key: Key('ride-with-others-mode-${mode.name}'),
                      contentPadding: EdgeInsets.zero,
                      value: mode,
                      title: Text(mode.label),
                      subtitle: Text(mode.description),
                    ),
                ],
              ),
            ),
          ],
          if (_needsName) ...[
            const SizedBox(height: 12),
            TextField(
              key: const Key('ride-with-others-name'),
              controller: _nameController,
              maxLength: 24,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Rider name',
                hintText: 'How the group will recognise you',
                counterText: '',
              ),
            ),
          ],
          if (_error case final message?) ...[
            const SizedBox(height: 12),
            Text(
              message,
              key: const Key('ride-with-others-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const Key('ride-with-others-create'),
            onPressed: _creating ? null : () => unawaited(_create()),
            icon: _creating
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.groups_2_outlined),
            label: Text(_error == null ? 'Create group ride' : 'Try again'),
          ),
        ],
      ),
    );
  }
}

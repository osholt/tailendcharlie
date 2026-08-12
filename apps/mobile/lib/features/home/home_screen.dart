import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../controllers/distance_unit_controller.dart';
import '../../controllers/completed_rides_controller.dart';
import '../../controllers/map_style_mode_controller.dart';
import '../../controllers/ride_code_preference_controller.dart';
import '../../controllers/ride_controller.dart';
import '../../controllers/rider_profile_controller.dart';
import '../../controllers/shared_route_controller.dart';
import '../../controllers/speed_limit_display_controller.dart';
import '../../controllers/ride_diagnostics_controller.dart';
import '../../controllers/spoken_guidance_controller.dart';
import 'home_map_backdrop.dart';
import 'home_ride_actions.dart';
import 'scan_invitation_screen.dart';
import '../../controllers/test_control_controller.dart';
import '../../domain/join_invite.dart';
import '../../domain/recorded_route_store.dart';
import '../../domain/ride_coordination_mode.dart';
import '../../domain/rider_color.dart';
import '../../internet/plan_directory.dart';
import '../../services/build_identity.dart';
import '../../services/gpx_import_source.dart';
import '../../services/stored_route_library.dart';
import '../map/motorcycle_icon.dart';
import '../map/rider_symbol_picker.dart';
import '../ride/route_recorder_screen.dart';
import '../ride/previous_rides_screen.dart';
import '../settings/about_build_sheet.dart';
import '../settings/emergency_info_sheet.dart';
import '../settings/unit_settings_sheet.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.distanceUnits,
    required this.mapStyleMode,
    required this.rideCodePreference,
    required this.riderProfile,
    required this.sharedRoutes,
    required this.speedLimitDisplay,
    required this.recordedRoutes,
    required this.completedRides,
    this.planDirectory,
    this.testControl,
    this.spokenGuidance,
    this.rideDiagnostics,
    this.restoringRideCode,
    this.restorationError,
    this.onRetryRestoration,
    this.enableNativeServices = true,
  });

  final RideController controller;
  final DistanceUnitController distanceUnits;
  final MapStyleModeController mapStyleMode;
  final RideCodePreferenceController rideCodePreference;
  final RiderProfileController riderProfile;
  final SharedRouteController sharedRoutes;
  final SpeedLimitDisplayController speedLimitDisplay;
  final RecordedRouteStore recordedRoutes;
  final CompletedRidesController completedRides;
  final PlanDirectory? planDirectory;

  /// Null unless this build carries the test-control define; only forwarded to
  /// the settings sheet.
  final TestControlController? testControl;

  /// Whether turn instructions are spoken (#286). Forwarded to the settings
  /// sheet, which is where a rider opts in.
  final SpokenGuidanceController? spokenGuidance;

  /// Null in an ordinary build. Threaded so the Settings sheet opened from
  /// *here* offers the recorder too — wiring only the ride shell's sheet is
  /// what hid it from a tester who had never started a ride (#419).
  final RideDiagnosticsController? rideDiagnostics;

  final String? restoringRideCode;
  final Object? restorationError;
  final VoidCallback? onRetryRestoration;

  /// False in widget tests and plugin-less builds; the map backdrop stands
  /// down rather than waiting on a platform map that will never load.
  final bool enableNativeServices;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _buildIdentity = BuildIdentity.fromEnvironment();

  @override
  void initState() {
    super.initState();
    final choice = widget.riderProfile.takePendingRideChoice();
    if (choice != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showRideSheet(
            context,
            creating: choice == OnboardingRideChoice.create,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The app opens on the map and the map is the *surface*, not a backdrop
      // (#426). #405 asked for this and #407 delivered a map behind a
      // full-screen panel — a brand mark, a heading, a paragraph, four buttons,
      // two links and a footer over a gradient covering the whole screen. From
      // the ride: "I don't want the start screen at all. I want the selection of
      // starting a ride to happen from the map view."
      //
      // So there is no panel and no scrim. What is left standing on the map is
      // one bar of actions at the bottom, the two controls at the top right, and
      // notices only when there is something to say.
      body: Stack(
        fit: StackFit.expand,
        children: [
          HomeMapBackdrop(
            mapStyleMode: widget.mapStyleMode,
            speedLimitDisplay: widget.speedLimitDisplay,
            distanceUnit: widget.distanceUnits.value,
            enableNativeServices: widget.enableNativeServices,
            // So the map's own "Show my location" control sits above the action
            // bar rather than under it.
            bottomInset: HomeRideActions.reservedHeight,
          ),
          SafeArea(
            child: Stack(
              children: [
                // Notices, and nothing when there are none. Each of these used
                // to sit in the scrolling column of a full-screen panel, which
                // is why the panel existed at all; they are now cards on the map
                // that appear and go.
                Positioned(
                  top: 52,
                  left: 12,
                  right: 12,
                  child: _HomeNotices(children: _notices(context)),
                ),
                Positioned(
                  top: 4,
                  right: 8,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Emergency info',
                        onPressed: () => EmergencyInfoSheet.show(
                          context,
                          widget.riderProfile,
                        ),
                        icon: const Icon(Icons.medical_information_outlined),
                      ),
                      IconButton(
                        tooltip: 'Settings',
                        onPressed: () => UnitSettingsSheet.show(
                          context,
                          widget.distanceUnits,
                          widget.mapStyleMode,
                          widget.riderProfile,
                          speedLimitDisplay: widget.speedLimitDisplay,
                          testControl: widget.testControl,
                          spokenGuidance: widget.spokenGuidance,
                          rideDiagnostics: widget.rideDiagnostics,
                        ),
                        icon: const Icon(Icons.settings_outlined),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: HomeRideActions(
              enabled:
                  !widget.controller.busy && widget.onRetryRestoration == null,
              onCreate: () => _showRideSheet(context, creating: true),
              onJoin: () => _showRideSheet(context, creating: false),
              onMore: () => unawaited(_showMoreActions(context)),
            ),
          ),
        ],
      ),
    );
  }

  /// The banners that have something to say right now.
  ///
  /// Returned as a list rather than built inline so "are there any" is a question
  /// the layout can answer — a notices area that reserved space for nothing would
  /// be a small panel, which is the thing being removed.
  List<Widget> _notices(BuildContext context) => [
    TesterUpdateBanner(identity: _buildIdentity),
    if (widget.onRetryRestoration != null)
      _RideRestorationBanner(
        rideCode: widget.restoringRideCode,
        error: widget.restorationError,
        onRetry: widget.onRetryRestoration!,
      ),
    if (widget.controller.endedRideSetAside)
      _SetAsideRideBanner(
        rideCode: widget.controller.session!.rideCode,
        onReopen: widget.controller.reopenEndedRide,
      ),
    if (widget.sharedRoutes.pending case final file?)
      _PendingSharedRouteBanner(
        fileName: file.name,
        onDismiss: widget.sharedRoutes.clearPending,
      ),
    if (widget.sharedRoutes.plannerLinkStatus != PlannerLinkStatus.idle)
      _PlannerLinkStatusBanner(
        status: widget.sharedRoutes.plannerLinkStatus,
        message:
            widget.sharedRoutes.plannerLinkMessage ?? 'Loading shared route…',
        canRetry: widget.sharedRoutes.canRetryPlannerLink,
        onRetry: () => unawaited(widget.sharedRoutes.retryPlannerLink()),
        onDismiss: widget.sharedRoutes.clearPlannerLinkNotice,
      ),
  ];

  /// The occasional actions, behind one button.
  ///
  /// Each of these was a permanent row on the old panel. None is used often enough
  /// to be worth a strip of map, and together they were most of what made the
  /// panel full-screen.
  Future<void> _showMoreActions(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: const Color(0xFF171D25),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('start-ride-simulator'),
              leading: const Icon(Icons.science_outlined),
              title: const Text('Try a simulated ride'),
              subtitle: const Text('Never shares your location'),
              enabled:
                  !widget.controller.busy && widget.onRetryRestoration == null,
              onTap: () {
                Navigator.of(sheetContext).pop();
                widget.controller.createSimulationRide();
              },
            ),
            ListTile(
              key: const Key('record-a-route-button'),
              leading: const Icon(Icons.fiber_manual_record_outlined),
              title: const Text('Record a route'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(
                  RouteRecorderScreen.show(context, widget.recordedRoutes),
                );
              },
            ),
            ListTile(
              key: const Key('previous-rides-button'),
              leading: const Icon(Icons.history),
              title: Text(
                widget.completedRides.rides.isEmpty
                    ? 'Previous rides'
                    : 'Previous rides (${widget.completedRides.rides.length})',
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(_openPreviousRides(context));
              },
            ),
            const Divider(height: 8),
            ListTile(
              key: const Key('home-build-identity'),
              leading: const Icon(Icons.info_outline),
              title: Text(
                '${_buildIdentity.versionLabel} · '
                '${_buildIdentity.track.label}',
              ),
              subtitle: const Text('No account required'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(
                  AboutBuildSheet.show(context, identity: _buildIdentity),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showRideSheet(
    BuildContext context, {
    required bool creating,
    PendingInAppRoute? pendingInAppRoute,
  }) async {
    widget.controller.clearError();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF171D25),
      builder: (sheetContext) => _RideForm(
        controller: widget.controller,
        rideCodePreference: widget.rideCodePreference,
        riderProfile: widget.riderProfile,
        sharedRoutes: widget.sharedRoutes,
        planDirectory: widget.planDirectory,
        creating: creating,
        pendingInAppRoute: pendingInAppRoute,
        onComplete: () => Navigator.of(sheetContext).pop(),
      ),
    );
  }

  Future<void> _openPreviousRides(BuildContext launchContext) async {
    final selection = await PreviousRidesScreen.show(
      launchContext,
      widget.completedRides,
      widget.distanceUnits,
    );
    if (selection == null || !mounted) return;
    final library = StoredRouteLibrary(
      recordedRoutes: widget.recordedRoutes,
      completedRides: widget.completedRides,
    );
    final prepared = library.prepare(selection);
    await _showRideSheet(
      context,
      creating: true,
      pendingInAppRoute: PendingInAppRoute(
        route: prepared.route,
        reviewNotes: prepared.notes,
      ),
    );
  }
}

class _RideRestorationBanner extends StatelessWidget {
  const _RideRestorationBanner({
    required this.rideCode,
    required this.error,
    required this.onRetry,
  });

  final String? rideCode;
  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = error != null;
    final ride = rideCode == null ? 'your saved ride' : 'ride $rideCode';
    return Container(
      key: const Key('ride-restoration-banner'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1D2530),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: failed
              ? Theme.of(context).colorScheme.error
              : const Color(0xFF3B4654),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (failed)
            Icon(
              Icons.warning_amber_rounded,
              color: Theme.of(context).colorScheme.error,
            )
          else
            const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  failed ? 'Could not restore $ride' : 'Still restoring $ride',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  failed
                      ? 'The home screen remains available. Retry before '
                            'creating or joining another ride.'
                      : 'The home screen remains available while its journal '
                            'loads. Ride actions will unlock when it is ready.',
                ),
                if (failed) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: const Key('retry-ride-restoration'),
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry restore'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SetAsideRideBanner extends StatelessWidget {
  const _SetAsideRideBanner({required this.rideCode, required this.onReopen});

  final String rideCode;
  final VoidCallback onReopen;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('set-aside-ride-banner'),
    margin: const EdgeInsets.only(bottom: 20),
    padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
    decoration: BoxDecoration(
      color: const Color(0xFF1D2530),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xFF3B4654)),
    ),
    child: Row(
      children: [
        const Icon(Icons.flag_outlined, color: Color(0xFFFFB15C)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Ride $rideCode has ended',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const Text(
                'Its summary and recap are still here.',
                style: TextStyle(color: Color(0xFFABB5C1), fontSize: 12),
              ),
            ],
          ),
        ),
        TextButton(
          key: const Key('reopen-set-aside-ride'),
          onPressed: onReopen,
          child: const Text('Open'),
        ),
      ],
    ),
  );
}

/// A GPX file opened from another app (Files, Mail, a route planner's share
/// sheet) has nowhere to go yet - there is no ride to attach a route to until
/// one exists. Surfaces that instead of silently discarding it.
class _PendingSharedRouteBanner extends StatelessWidget {
  const _PendingSharedRouteBanner({
    required this.fileName,
    required this.onDismiss,
  });

  final String fileName;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
    decoration: BoxDecoration(
      color: const Color(0xFF1D2530),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0xFF3B4654)),
    ),
    child: Row(
      children: [
        const Icon(Icons.map_outlined, color: Color(0xFFFFB15C)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                fileName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const Text(
                'Start or join a ride, then reopen it to use this route.',
                style: TextStyle(color: Color(0xFFABB5C1), fontSize: 12),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Dismiss',
          onPressed: onDismiss,
          icon: const Icon(Icons.close, size: 20),
        ),
      ],
    ),
  );
}

class _PlannerLinkStatusBanner extends StatelessWidget {
  const _PlannerLinkStatusBanner({
    required this.status,
    required this.message,
    required this.canRetry,
    required this.onRetry,
    required this.onDismiss,
  });

  final PlannerLinkStatus status;
  final String message;
  final bool canRetry;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('planner-link-status'),
    padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
    decoration: BoxDecoration(
      color: const Color(0xFF1D2530),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: status == PlannerLinkStatus.error
            ? const Color(0xFFD96A6A)
            : const Color(0xFF3B4654),
      ),
    ),
    child: Row(
      children: [
        if (status == PlannerLinkStatus.loading)
          const SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          const Icon(Icons.link_off, color: Color(0xFFFFB15C)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            message,
            style: const TextStyle(color: Color(0xFFD2D9E1), fontSize: 13),
          ),
        ),
        if (canRetry)
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        if (status == PlannerLinkStatus.error)
          IconButton(
            tooltip: 'Dismiss route link message',
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 20),
          ),
      ],
    ),
  );
}

class _RideForm extends StatefulWidget {
  const _RideForm({
    required this.controller,
    required this.rideCodePreference,
    required this.riderProfile,
    required this.sharedRoutes,
    required this.planDirectory,
    required this.creating,
    required this.onComplete,
    this.pendingInAppRoute,
  });

  final RideController controller;
  final RideCodePreferenceController rideCodePreference;
  final RiderProfileController riderProfile;
  final SharedRouteController sharedRoutes;
  final PlanDirectory? planDirectory;
  final bool creating;
  final VoidCallback onComplete;
  final PendingInAppRoute? pendingInAppRoute;

  @override
  State<_RideForm> createState() => _RideFormState();
}

class _RideFormState extends State<_RideForm> with WidgetsBindingObserver {
  late final _nameController = TextEditingController(
    text: widget.riderProfile.displayName,
  );
  late final _codeController = TextEditingController(
    text: widget.creating ? null : widget.rideCodePreference.savedCode,
  );
  final _rideNameController = TextEditingController();
  final _planCodeController = TextEditingController();
  final _codeFocusNode = FocusNode();
  final _codeFieldKey = GlobalKey();
  late MotorcycleIconStyle _selectedStyle = widget.riderProfile.motorcycleStyle;
  late RiderSymbol _selectedSymbol = widget.riderProfile.riderSymbol;
  late RiderColor _selectedColor = widget.riderProfile.riderColor;
  RideCoordinationMode _selectedCoordinationMode =
      RideCoordinationMode.secondBikeDropOff;

  /// Set once a created ride's code needs sharing before handing off to the
  /// map - the moment a leader most needs it, with people waiting nearby.
  bool _showShareStep = false;
  bool _checkingPlanCode = false;
  String? _planCodeError;
  PickedGpxFile? _pendingPlanFile;

  /// Captured when pasted text includes a join token alongside the six
  /// digits - see [parseJoinInvite]. Typing the code by hand leaves this
  /// null, which still works but only via the rate-limited fallback.
  String? _pastedJoinToken;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _codeFocusNode.addListener(_keepCodeFieldVisible);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _codeFocusNode.removeListener(_keepCodeFieldVisible);
    _codeFocusNode.dispose();
    _nameController.dispose();
    _codeController.dispose();
    _rideNameController.dispose();
    _planCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_showShareStep) {
      return _ShareCodeStep(
        controller: widget.controller,
        onContinue: _finishCreating,
      );
    }
    return AnimatedBuilder(
      animation: Listenable.merge([
        widget.controller,
        widget.rideCodePreference,
      ]),
      builder: (context, _) => AnimatedPadding(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          key: const Key('ride-form-scroll-view'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.creating ? 'Create a private ride' : 'Join your group',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 8),
              Text(
                widget.creating
                    ? 'You will become the ride lead and get a six-digit code to share.'
                    : 'Enter the six-digit code shared by the ride lead. You need a connection once to join, then the app keeps using the secure relay.',
                style: const TextStyle(color: Color(0xFFABB5C1)),
              ),
              const SizedBox(height: 24),
              if (widget.creating) ...[
                Text(
                  'Who is riding?',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                SegmentedButton<bool>(
                  key: const Key('ride-scope-selector'),
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
                  selected: {_selectedCoordinationMode.isGroup},
                  onSelectionChanged: (selection) => setState(() {
                    _selectedCoordinationMode = selection.first
                        ? RideCoordinationMode.secondBikeDropOff
                        : RideCoordinationMode.solo;
                  }),
                ),
                const SizedBox(height: 8),
                Text(
                  _selectedCoordinationMode == RideCoordinationMode.solo
                      ? RideCoordinationMode.solo.description
                      : 'Choose how this group will handle junctions.',
                  style: const TextStyle(
                    color: Color(0xFFABB5C1),
                    fontSize: 13,
                  ),
                ),
                if (_selectedCoordinationMode.isGroup) ...[
                  const SizedBox(height: 12),
                  RadioGroup<RideCoordinationMode>(
                    groupValue: _selectedCoordinationMode,
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _selectedCoordinationMode = value);
                      }
                    },
                    child: Column(
                      children: [
                        for (final mode in const [
                          RideCoordinationMode.secondBikeDropOff,
                          RideCoordinationMode.keepTogether,
                        ])
                          RadioListTile<RideCoordinationMode>(
                            key: Key('ride-mode-${mode.name}'),
                            contentPadding: EdgeInsets.zero,
                            value: mode,
                            title: Text(mode.label),
                            subtitle: Text(mode.description),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: _rideNameController,
                  maxLength: 32,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Ride name (optional)',
                    hintText: 'e.g. Sunday coast run',
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('planned-route-code-field'),
                  controller: _planCodeController,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  maxLength: 16,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                    LengthLimitingTextInputFormatter(16),
                  ],
                  decoration: InputDecoration(
                    labelText: 'Planned route code (optional)',
                    hintText: 'e.g. 7F3K9QRT',
                    helperText:
                        'From the web planner. The route opens for review after the ride is created.',
                    errorText: _planCodeError,
                    counterText: '',
                    suffixIcon: const Icon(Icons.qr_code),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                key: const Key('rider-name-field'),
                controller: _nameController,
                autofocus: true,
                maxLength: 24,
                textCapitalization: TextCapitalization.words,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Rider name',
                  hintText: 'How the group will recognise you',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 16),
              RiderSymbolPicker(
                displayName: _nameController.text,
                selectedSymbol: _selectedSymbol,
                motorcycleStyle: _selectedStyle,
                badgeColor: _selectedColor.color,
                keyPrefix: 'ride-symbol',
                bikeKeyPrefix: 'bike-style',
                onSymbolChanged: (symbol) =>
                    setState(() => _selectedSymbol = symbol),
                onMotorcycleStyleChanged: (style) =>
                    setState(() => _selectedStyle = style),
              ),
              const SizedBox(height: 16),
              const Text(
                'Your colour',
                style: TextStyle(color: Color(0xFFABB5C1)),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: RiderColor.values.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final riderColor = RiderColor.values[index];
                    final selected = riderColor == _selectedColor;
                    return Tooltip(
                      message: riderColor.label,
                      child: InkWell(
                        key: Key('rider-colour-${riderColor.name}'),
                        customBorder: const CircleBorder(),
                        onTap: () =>
                            setState(() => _selectedColor = riderColor),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: riderColor.color,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: selected
                                  ? Colors.white
                                  : Colors.transparent,
                              width: 2.5,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Lead and Tail End Charlie always show in their own reserved colours, whatever you pick here.',
                  style: TextStyle(color: Color(0xFF7F8A98), fontSize: 12),
                ),
              ),
              if (!widget.creating) ...[
                const SizedBox(height: 12),
                KeyedSubtree(
                  key: _codeFieldKey,
                  child: TextField(
                    key: const Key('ride-code-field'),
                    controller: _codeController,
                    focusNode: _codeFocusNode,
                    scrollPadding: const EdgeInsets.only(bottom: 112),
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) {
                      if (!widget.controller.busy) _submit();
                    },
                    autocorrect: false,
                    maxLength: 6,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    decoration: InputDecoration(
                      labelText: 'Six-digit ride code',
                      hintText: '123456',
                      helperText: widget.rideCodePreference.savedCode == null
                          ? null
                          : 'Saved from your last successful join',
                      counterText: '',
                      // Scanning sits beside pasting rather than replacing it.
                      // A camera is the only join path that works with no signal
                      // (#279), and must never become the only path at all.
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: const Key('scan-invitation-button'),
                            tooltip: 'Scan an invitation code',
                            onPressed: _scanInvitation,
                            icon: const Icon(Icons.qr_code_scanner),
                          ),
                          IconButton(
                            tooltip: 'Paste ride code',
                            onPressed: _pasteRideCode,
                            icon: const Icon(Icons.content_paste),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // The same action as the camera icon in the field above, said
                // out loud.
                //
                // #279 shipped QR joining and #306 found it had not been
                // delivered: the owner concluded it was missing entirely,
                // because the only affordance was an unlabelled icon and a
                // tooltip, and a tooltip does not appear when you tap a phone.
                // The icon stays for riders who have learned it; this is the
                // one a rider who has never seen the app can read.
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const Key('scan-invitation-labelled-button'),
                    onPressed: _scanInvitation,
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Scan an invitation code'),
                  ),
                ),
                CheckboxListTile(
                  key: const Key('keep-ride-code'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: widget.rideCodePreference.keepCode,
                  onChanged: (value) {
                    if (value != null) {
                      widget.rideCodePreference.setKeepCode(value);
                    }
                  },
                  title: const Text('Keep this code for next time'),
                  subtitle: const Text(
                    'Only the six-digit code is saved. Invitation secrets are not.',
                  ),
                ),
                if (widget.rideCodePreference.savedCode != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('forget-saved-ride-code'),
                      onPressed: _forgetSavedCode,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Forget saved code'),
                    ),
                  ),
              ],
              if (widget.controller.errorMessage case final String message) ...[
                const SizedBox(height: 12),
                Text(
                  message,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                // A connection or service failure is worth another go, and there
                // was nothing to press: the rider read a sentence about a relay
                // handshake and had to guess (#208).
                if (widget.controller.errorIsRetryable)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('retry-ride-submit'),
                      onPressed: widget.controller.busy || _checkingPlanCode
                          ? null
                          : () {
                              widget.controller.clearError();
                              unawaited(_submit());
                            },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  ),
              ],
              const SizedBox(height: 22),
              FilledButton(
                onPressed: widget.controller.busy || _checkingPlanCode
                    ? null
                    : _submit,
                child: widget.controller.busy || _checkingPlanCode
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(widget.creating ? 'Create ride' : 'Join ride'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final name = _nameController.text;
    if (widget.creating) {
      final code = _planCodeController.text.trim();
      _pendingPlanFile = null;
      if (code.isNotEmpty) {
        setState(() {
          _checkingPlanCode = true;
          _planCodeError = null;
        });
        final ownedDirectory = widget.planDirectory == null
            ? HttpPlanDirectory.fromEnvironment()
            : null;
        try {
          final plan = await (widget.planDirectory ?? ownedDirectory!).fetch(
            code,
          );
          _pendingPlanFile = PickedGpxFile(
            name: '${plan.name ?? 'planned-route'}.gpx',
            bytes: Uint8List.fromList(utf8.encode(plan.gpx)),
          );
        } on PlanDirectoryException catch (error) {
          if (mounted) setState(() => _planCodeError = error.message);
          return;
        } on Object {
          if (mounted) {
            setState(
              () => _planCodeError =
                  'The planned route could not be loaded. Check your connection and try again.',
            );
          }
          return;
        } finally {
          ownedDirectory?.close();
          if (mounted) setState(() => _checkingPlanCode = false);
        }
      }
      await widget.controller.createRide(
        name,
        motorcycleStyle: _selectedStyle,
        riderSymbol: _selectedSymbol,
        riderColor: _selectedColor,
        coordinationMode: _selectedCoordinationMode,
        rideName: _rideNameController.text,
      );
    } else {
      final code = _codeController.text.trim();
      await widget.controller.joinRide(
        code,
        name,
        motorcycleStyle: _selectedStyle,
        riderSymbol: _selectedSymbol,
        riderColor: _selectedColor,
        joinToken: _pastedJoinToken,
      );
      if (widget.controller.hasActiveRide) {
        await widget.rideCodePreference.rememberSuccessfulJoin(code);
      } else if (widget.controller.errorMessage?.startsWith(
            'That ride code is not active.',
          ) ??
          false) {
        await widget.rideCodePreference.clearIfInactive(code);
      }
    }
    if (widget.controller.hasActiveRide && mounted) {
      await widget.riderProfile.save(
        displayName: name.trim(),
        motorcycleStyle: _selectedStyle,
        riderSymbol: _selectedSymbol,
        riderColor: _selectedColor,
      );
      if (widget.creating) {
        if (_selectedCoordinationMode.isGroup) {
          setState(() => _showShareStep = true);
        } else {
          _finishCreating();
        }
      } else {
        widget.onComplete();
      }
    }
  }

  void _finishCreating() {
    if (_pendingPlanFile case final file?) {
      widget.sharedRoutes.stagePending(file);
      _pendingPlanFile = null;
    } else if (widget.pendingInAppRoute case final route?) {
      widget.sharedRoutes.stagePendingInAppRoute(
        route.route,
        reviewNotes: route.reviewNotes,
      );
    }
    widget.onComplete();
  }

  @override
  void didChangeMetrics() {
    if (!_codeFocusNode.hasFocus) return;
    Future<void>.delayed(const Duration(milliseconds: 220), () {
      if (mounted) _keepCodeFieldVisible();
    });
  }

  void _keepCodeFieldVisible() {
    if (!_codeFocusNode.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final fieldContext = _codeFieldKey.currentContext;
      if (!mounted || fieldContext == null) return;
      Scrollable.ensureVisible(
        fieldContext,
        alignment: 0.55,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _forgetSavedCode() async {
    final savedCode = widget.rideCodePreference.savedCode;
    await widget.rideCodePreference.clear();
    if (_codeController.text == savedCode) _codeController.clear();
  }

  /// Scans an invitation and joins from it, with no relay lookup (#279).
  ///
  /// The whole point is that this works with no signal, so it joins directly from
  /// the scanned credentials rather than filling in the code field and going
  /// through the online path - which would defeat it.
  Future<void> _scanInvitation() async {
    final invitation = await ScanInvitationScreen.show(context);
    if (invitation == null || !mounted) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      // Ask for the name rather than joining as nobody: the roster is how a group
      // finds each other.
      setState(() => _codeController.text = invitation.rideCode);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Add your rider name, then join.')),
      );
      return;
    }
    await widget.controller.joinRideFromInvitation(
      invitation,
      name,
      motorcycleStyle: _selectedStyle,
      riderSymbol: _selectedSymbol,
      riderColor: _selectedColor,
    );
    if (!mounted) return;
    if (widget.controller.hasActiveRide) {
      await widget.rideCodePreference.rememberSuccessfulJoin(
        invitation.rideCode,
      );
    }
  }

  Future<void> _pasteRideCode() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) return;
    final invite = parseJoinInvite(text);
    final code = invite.code ?? text;
    _pastedJoinToken = invite.token;
    _codeController.text = code;
    _codeController.selection = TextSelection.collapsed(offset: code.length);
  }
}

/// Shown immediately after creating a ride - the moment a leader most needs
/// the code, with riders waiting nearby, rather than requiring a trip
/// through the active Ride page to find it.
class _ShareCodeStep extends StatelessWidget {
  const _ShareCodeStep({required this.controller, required this.onContinue});

  final RideController controller;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final session = controller.session;
    final code = session?.rideCode ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF6ED89A), size: 40),
          const SizedBox(height: 16),
          Text(
            session?.rideName ?? 'Ride created',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Share this code so the group can join.',
            style: TextStyle(color: Color(0xFFABB5C1)),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 18),
            decoration: BoxDecoration(
              color: const Color(0xFF111720),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF2A3441)),
            ),
            child: Center(
              child: Text(
                code,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 34,
                  letterSpacing: 6,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => Clipboard.setData(ClipboardData(text: code)),
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => SharePlus.instance.share(
                    ShareParams(
                      text: controller.rideCodeShareText,
                      subject: 'Join my Tail End Charlie group',
                    ),
                  ),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('Share'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          TextButton(
            onPressed: onContinue,
            child: const Text('Continue to ride'),
          ),
        ],
      ),
    );
  }
}

/// The notices area: compact cards on the map, and nothing at all when there is
/// nothing to say (#426).
///
/// The old home screen carried these in the scrolling column of a full-screen
/// panel, which is most of why the panel was full-screen. They still need a home —
/// a restoration failure, a set-aside ride, a pending shared route and a planner
/// link all matter — but not one that reserves space when empty.
///
/// Scrollable because several can be live at once and the map must not be pushed
/// off the screen by a stack of them.
class _HomeNotices extends StatelessWidget {
  const _HomeNotices({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final visible = children.where((child) => child is! SizedBox).toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      // A third of the screen at most. A notice is worth interrupting the map
      // for; four notices are not worth losing it.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height / 3,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final child in visible)
              Padding(padding: const EdgeInsets.only(bottom: 10), child: child),
          ],
        ),
      ),
    );
  }
}

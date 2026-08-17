import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/distance_unit_controller.dart';
import '../controllers/global_ride_heatmap_controller.dart';
import '../controllers/completed_rides_controller.dart';
import '../controllers/map_style_mode_controller.dart';
import '../controllers/ride_code_preference_controller.dart';
import '../controllers/ride_controller.dart';
import '../controllers/ride_invitation_link_controller.dart';
import '../controllers/route_progress_display_controller.dart';
import '../controllers/rider_profile_controller.dart';
import '../controllers/road_rating_controller.dart';
import '../controllers/shared_route_controller.dart';
import '../controllers/ride_diagnostics_controller.dart';
import '../controllers/speed_limit_display_controller.dart';
import '../controllers/spoken_guidance_controller.dart';
import '../controllers/test_control_controller.dart';
import '../domain/recorded_route_store.dart';
import '../features/home/home_screen.dart';
import 'ride_invitation_link_gate.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/ride/active_ride_shell.dart';
import '../internet/plan_directory.dart';
import '../services/test_control_registry.dart';

class RideRelayApp extends StatelessWidget {
  const RideRelayApp({
    super.key,
    required this.controller,
    required this.distanceUnits,
    required this.mapStyleMode,
    required this.rideCodePreference,
    required this.riderProfile,
    required this.sharedRoutes,
    required this.speedLimitDisplay,
    this.routeProgressDisplay,
    required this.recordedRoutes,
    required this.completedRides,
    this.globalRideHeatmap,
    this.rideInvitationLinks,
    this.planDirectory,
    this.roadRatings,
    this.testControl,
    this.testControlRegistry,
    this.spokenGuidance,
    this.rideDiagnostics,
    this.enableNativeServices = true,
    this.initializeController,
    this.startupFallbackAfter = const Duration(seconds: 2),
  });

  final RideController controller;
  final DistanceUnitController distanceUnits;
  final MapStyleModeController mapStyleMode;
  final RideCodePreferenceController rideCodePreference;
  final RiderProfileController riderProfile;
  final SharedRouteController sharedRoutes;
  final SpeedLimitDisplayController speedLimitDisplay;
  final RouteProgressDisplayController? routeProgressDisplay;
  final RecordedRouteStore recordedRoutes;
  final CompletedRidesController completedRides;
  final GlobalRideHeatmapController? globalRideHeatmap;
  final RideInvitationLinkController? rideInvitationLinks;
  final PlanDirectory? planDirectory;

  /// Drives the end-of-ride catalogued-road rating card (#159).
  final RoadRatingController? roadRatings;

  /// Both null unless this build carries the test-control define. The settings
  /// row and the registry hand-off are the only two places they are used.
  final TestControlController? testControl;
  final TestControlRegistry? testControlRegistry;

  /// Whether turn instructions are spoken (#286). Off by default.
  final SpokenGuidanceController? spokenGuidance;

  /// Records what the app said beside what the bike did, when an instrumented
  /// build has it switched on (#419). Null in an ordinary build.
  final RideDiagnosticsController? rideDiagnostics;

  final bool enableNativeServices;

  /// Production starts restoration after the first frame instead of holding the
  /// native launch screen until the ride journal has loaded (#209).
  ///
  /// Tests and embedders that provide an already-initialized controller leave
  /// this null and retain the existing immediate behavior.
  final Future<void> Function()? initializeController;

  /// How long the dedicated restore screen may own the app before the normal
  /// home screen is exposed with the persisted ride named there.
  final Duration startupFallbackAfter;

  @override
  Widget build(BuildContext context) => _RideRestoreGate(app: this);

  Widget _buildApp({
    required bool restorationComplete,
    required bool showRestorationFallback,
    required Object? restorationError,
    required VoidCallback retryRestoration,
    required bool openJoinGroup,
    required VoidCallback requestJoinGroup,
    required VoidCallback consumeJoinGroupRequest,
    required bool showRecoveredRideChoice,
    required VoidCallback rejoinRecoveredRide,
    required Future<void> Function() endRecoveredRide,
  }) {
    const background = Color(0xFF0D1117);
    const surface = Color(0xFF171D25);
    const orange = Color(0xFFFF7A1A);

    final rideSurface = AnimatedBuilder(
      animation: Listenable.merge([
        controller,
        distanceUnits,
        mapStyleMode,
        completedRides,
        sharedRoutes,
        riderProfile,
        speedLimitDisplay,
        ?routeProgressDisplay,
      ]),
      builder: (context, _) {
        if (!restorationComplete && !showRestorationFallback) {
          return const _RideRestoreScreen();
        }
        if (!restorationComplete) {
          return HomeScreen(
            controller: controller,
            distanceUnits: distanceUnits,
            mapStyleMode: mapStyleMode,
            rideCodePreference: rideCodePreference,
            riderProfile: riderProfile,
            sharedRoutes: sharedRoutes,
            speedLimitDisplay: speedLimitDisplay,
            routeProgressDisplay: routeProgressDisplay,
            recordedRoutes: recordedRoutes,
            completedRides: completedRides,
            globalRideHeatmap: globalRideHeatmap,
            planDirectory: planDirectory,
            testControl: testControl,
            spokenGuidance: spokenGuidance,
            rideDiagnostics: rideDiagnostics,
            restoringRideCode: controller.session?.rideCode,
            restorationError: restorationError,
            onRetryRestoration: retryRestoration,
            openJoinGroup: openJoinGroup,
            onJoinGroupOpened: consumeJoinGroupRequest,
            enableNativeServices: enableNativeServices,
          );
        }
        if (showRecoveredRideChoice) {
          return _RecoveredRideChoiceScreen(
            rideName: controller.session?.rideName,
            rideCode: controller.session?.rideCode,
            onRejoin: rejoinRecoveredRide,
            onEnd: endRecoveredRide,
          );
        }
        // An ended ride the rider has stepped away from stays on the phone and
        // stays archived; it just stops owning the whole screen (#207).
        if (controller.hasActiveRide && !controller.endedRideSetAside) {
          return ActiveRideShell(
            key: ValueKey(controller.session!.rideId),
            rideController: controller,
            distanceUnits: distanceUnits,
            mapStyleMode: mapStyleMode,
            eventStore: controller.eventStore,
            enableNativeServices: enableNativeServices,
            riderProfile: riderProfile,
            sharedRoutes: sharedRoutes,
            speedLimitDisplay: speedLimitDisplay,
            routeProgressDisplay: routeProgressDisplay,
            completedRideStore: completedRides,
            globalRideHeatmap: globalRideHeatmap,
            roadRatings: roadRatings,
            testControl: testControl,
            testControlRegistry: testControlRegistry,
            spokenGuidance: spokenGuidance,
            rideDiagnostics: rideDiagnostics,
            onJoinGroupRequested: requestJoinGroup,
          );
        }
        if (riderProfile.needsOnboarding) {
          return OnboardingScreen(riderProfile: riderProfile);
        }
        return HomeScreen(
          controller: controller,
          distanceUnits: distanceUnits,
          mapStyleMode: mapStyleMode,
          rideCodePreference: rideCodePreference,
          riderProfile: riderProfile,
          sharedRoutes: sharedRoutes,
          speedLimitDisplay: speedLimitDisplay,
          routeProgressDisplay: routeProgressDisplay,
          recordedRoutes: recordedRoutes,
          completedRides: completedRides,
          globalRideHeatmap: globalRideHeatmap,
          planDirectory: planDirectory,
          testControl: testControl,
          spokenGuidance: spokenGuidance,
          rideDiagnostics: rideDiagnostics,
          openJoinGroup: openJoinGroup,
          onJoinGroupOpened: consumeJoinGroupRequest,
          enableNativeServices: enableNativeServices,
        );
      },
    );
    final links = rideInvitationLinks;

    return MaterialApp(
      title: 'Tail End Charlie',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: orange,
          brightness: Brightness.dark,
          surface: surface,
        ),
        textTheme: const TextTheme(
          displaySmall: TextStyle(
            fontWeight: FontWeight.w800,
            letterSpacing: -1.2,
          ),
          headlineMedium: TextStyle(
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
          ),
          titleLarge: TextStyle(fontWeight: FontWeight.w700),
          titleMedium: TextStyle(fontWeight: FontWeight.w700),
        ),
        cardTheme: const CardThemeData(
          color: surface,
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF111720),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFF2A3441)),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 54),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 54),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            side: const BorderSide(color: Color(0xFF3B4654)),
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
      home: links == null
          ? rideSurface
          : RideInvitationLinkGate(
              links: links,
              rideController: controller,
              rideCodePreference: rideCodePreference,
              riderProfile: riderProfile,
              ready: restorationComplete,
              child: rideSurface,
            ),
    );
  }
}

class _RideRestoreGate extends StatefulWidget {
  const _RideRestoreGate({required this.app});

  final RideRelayApp app;

  @override
  State<_RideRestoreGate> createState() => _RideRestoreGateState();
}

class _RideRestoreGateState extends State<_RideRestoreGate> {
  Timer? _fallbackTimer;
  bool _restorationComplete = false;
  bool _showRestorationFallback = false;
  Object? _restorationError;
  int _attempt = 0;
  bool _openJoinGroup = false;
  bool _showRecoveredRideChoice = false;

  @override
  void initState() {
    super.initState();
    _restorationComplete = widget.app.initializeController == null;
    if (!_restorationComplete) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _beginRestoration();
      });
    }
  }

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    super.dispose();
  }

  void _beginRestoration() {
    final initialize = widget.app.initializeController;
    if (initialize == null) return;
    final attempt = ++_attempt;
    _fallbackTimer?.cancel();
    setState(() {
      _restorationComplete = false;
      _showRestorationFallback = false;
      _restorationError = null;
    });
    _fallbackTimer = Timer(widget.app.startupFallbackAfter, () {
      if (!mounted || attempt != _attempt) return;
      setState(() => _showRestorationFallback = true);
    });
    Future<void>.sync(initialize).then(
      (_) {
        if (!mounted || attempt != _attempt) return;
        _fallbackTimer?.cancel();
        setState(() {
          _restorationComplete = true;
          _showRestorationFallback = false;
          _showRecoveredRideChoice =
              widget.app.controller.hasActiveRide &&
              widget.app.controller.rideStarted &&
              !widget.app.controller.rideEnded;
        });
      },
      onError: (Object error, StackTrace _) {
        if (!mounted || attempt != _attempt) return;
        _fallbackTimer?.cancel();
        setState(() {
          _restorationError = error;
          _showRestorationFallback = true;
        });
      },
    );
  }

  void _requestJoinGroup() {
    if (mounted) setState(() => _openJoinGroup = true);
  }

  void _consumeJoinGroupRequest() {
    if (mounted && _openJoinGroup) setState(() => _openJoinGroup = false);
  }

  void _rejoinRecoveredRide() {
    if (mounted) setState(() => _showRecoveredRideChoice = false);
  }

  Future<void> _endRecoveredRide() async {
    final controller = widget.app.controller;
    if (controller.isLocalRideLeader) {
      await controller.endRide();
    } else {
      await controller.leaveRide();
    }
    if (mounted) setState(() => _showRecoveredRideChoice = false);
  }

  @override
  Widget build(BuildContext context) => widget.app._buildApp(
    restorationComplete: _restorationComplete,
    showRestorationFallback: _showRestorationFallback,
    restorationError: _restorationError,
    retryRestoration: _beginRestoration,
    openJoinGroup: _openJoinGroup,
    requestJoinGroup: _requestJoinGroup,
    consumeJoinGroupRequest: _consumeJoinGroupRequest,
    showRecoveredRideChoice: _showRecoveredRideChoice,
    rejoinRecoveredRide: _rejoinRecoveredRide,
    endRecoveredRide: _endRecoveredRide,
  );
}

class _RecoveredRideChoiceScreen extends StatefulWidget {
  const _RecoveredRideChoiceScreen({
    required this.rideName,
    required this.rideCode,
    required this.onRejoin,
    required this.onEnd,
  });

  final String? rideName;
  final String? rideCode;
  final VoidCallback onRejoin;
  final Future<void> Function() onEnd;

  @override
  State<_RecoveredRideChoiceScreen> createState() =>
      _RecoveredRideChoiceScreenState();
}

class _RecoveredRideChoiceScreenState
    extends State<_RecoveredRideChoiceScreen> {
  bool _ending = false;

  @override
  Widget build(BuildContext context) {
    final title = widget.rideName?.trim();
    return Scaffold(
      body: SafeArea(
        // Top-aligned, not centred (#594). A panel floating in the middle of an
        // otherwise empty screen reads as a modal that has gone wrong, and it
        // put the two actions where a thumb is least likely to be. Scrollable
        // with it, so the actions stay reachable at large text sizes.
        child: SingleChildScrollView(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(
                      Icons.restore,
                      size: 54,
                      color: Color(0xFFFF7A1A),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Ride recovered',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '${title?.isNotEmpty == true ? title : 'Ride ${widget.rideCode ?? ''}'} was still running when the app closed. '
                      'Rejoin it, or end it and keep the recorded ride in your Ride Library.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFABB5C1),
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      key: const Key('rejoin-recovered-ride'),
                      onPressed: _ending ? null : widget.onRejoin,
                      icon: const Icon(Icons.navigation_outlined),
                      label: const Text('Rejoin ride'),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      key: const Key('end-recovered-ride'),
                      onPressed: _ending
                          ? null
                          : () async {
                              setState(() => _ending = true);
                              try {
                                await widget.onEnd();
                              } finally {
                                if (mounted) setState(() => _ending = false);
                              }
                            },
                      icon: _ending
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.stop_circle_outlined),
                      label: const Text('End and save ride'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RideRestoreScreen extends StatelessWidget {
  const _RideRestoreScreen();

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.flag_outlined, size: 42, color: Color(0xFFFF7A1A)),
            SizedBox(height: 18),
            Text(
              'Restoring your ride…',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 18),
            CircularProgressIndicator(),
          ],
        ),
      ),
    ),
  );
}

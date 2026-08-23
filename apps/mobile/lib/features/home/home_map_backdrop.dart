import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/foreground_location_controller.dart';
import '../../controllers/global_ride_heatmap_controller.dart';
import '../../controllers/map_style_mode_controller.dart';
import '../../controllers/shared_route_controller.dart' show PendingInAppRoute;
import '../../controllers/speed_limit_display_controller.dart';
import '../../controllers/spoken_guidance_controller.dart';
import '../../domain/completed_ride.dart';
import '../../domain/distance_unit.dart';
import '../../domain/completed_ride_store.dart';
import '../../domain/geo_point.dart' as awareness_geo;
import '../../domain/imported_route.dart' as route_domain;
import '../../domain/map_style_mode.dart';
import '../../domain/rider_location.dart';
import '../../domain/route_authority.dart';
import '../../services/device_location_source.dart';
import '../../services/free_roam_ride_recorder.dart';
import '../../services/geo_calculations.dart';
import '../../services/measurement_formatter.dart';
import '../../services/navigation_guidance.dart';
import '../../services/spoken_audio_mode.dart';
import '../../services/spoken_guidance.dart';
import '../../services/spoken_guidance_schedule.dart';
import '../map/ride_map_feature.dart';

/// The live map the app opens on (#405).
///
/// The app used to open on a form, so the one surface that is useful before any
/// decision has been made — where am I, what is this road — was behind the
/// decision. This puts the map underneath the home actions instead.
///
/// **It never asks for location on open.** A rider who has already granted
/// access sees themselves immediately; a rider who has not sees the map with no
/// position and a labelled control that asks. Opening an app straight into a
/// permission prompt, before it has shown what it is for, is the thing this
/// deliberately does not do — and the ride flows that genuinely need location
/// still ask at the point they need it.
class HomeMapBackdrop extends StatefulWidget {
  const HomeMapBackdrop({
    super.key,
    required this.mapStyleMode,
    required this.speedLimitDisplay,
    required this.distanceUnit,
    this.spokenGuidance,
    this.enableNativeServices = true,
    this.locationController,
    this.bottomInset = 0,
    this.position,
    this.completedRideStore,
    this.globalRideHeatmap,
    this.onMapStyleResolved,
    this.hostChrome,
    this.pendingInAppRoute,
    this.changeRouteRequestToken,
    this.onChangeRouteRequestHandled,
    this.circularRideRequestToken,
    this.onCircularRideRequestHandled,
    this.onRouteChanged,
    this.localDisplayName = 'Rider',
    this.onNavigationArchived,
    this.navigating = false,
  });

  /// Height kept clear at the bottom for whatever stands on the map.
  ///
  /// Usually zero on Home. Kept as an embedding contract so a host that adds
  /// bottom chrome can keep the map's location control above it.
  final double bottomInset;

  /// Where the rider is, published for the screen above to use.
  ///
  /// Supplied by [HomeScreen] so a searched destination can be routed from *here*
  /// without this widget owning a position nothing else can reach (#431). When
  /// absent it keeps its own, as it did before there was anything to tell.
  final ValueNotifier<route_domain.GeoPoint?>? position;

  final MapStyleModeController mapStyleMode;
  final SpeedLimitDisplayController speedLimitDisplay;
  final SpokenGuidanceController? spokenGuidance;
  final DistanceUnit distanceUnit;
  final CompletedRideStore? completedRideStore;
  final GlobalRideHeatmapController? globalRideHeatmap;
  final ValueChanged<String>? onMapStyleResolved;

  /// The home screen's own top-band chrome, handed to the map to draw rather
  /// than painted over it. See [HostMapChrome] — this is what stopped the
  /// discovery-layer menu being buried under the settings button (#572, #573).
  final HostMapChrome? hostChrome;

  /// A route the home screen has planned, for the map to review and follow.
  ///
  /// Free roam plans its own destinations now rather than creating a ride to
  /// hold one (#600). The route arrives by the same handoff a shared GPX uses,
  /// so it lands in the same review the ride map gives an imported route
  /// instead of a second, free-roam-shaped one.
  final PendingInAppRoute? pendingInAppRoute;

  /// Changes when [pendingInAppRoute] is a new request. The map ignores a
  /// route it has already taken, so this is what says "again".
  final Object? changeRouteRequestToken;
  final VoidCallback? onChangeRouteRequestHandled;

  /// Requests the map's existing circular-route planner from Home's search
  /// sheet. A token is consumed once, like the route-change handoff above.
  final Object? circularRideRequestToken;
  final VoidCallback? onCircularRideRequestHandled;

  /// Fires with the route the map is following, or null when there is none —
  /// including the one restored from the last session.
  final ValueChanged<route_domain.ImportedRoute?>? onRouteChanged;

  /// The local identity stored beside personal navigation history.
  final String localDisplayName;

  /// Fires after a Where To session has been saved into My rides.
  final ValueChanged<CompletedRide>? onNavigationArchived;

  /// Whether this map is following a route.
  ///
  /// Free roam has no ride to start, so the guidance chrome cannot key off one
  /// (#600). The home screen answers from what the map reports through
  /// [onRouteChanged], which is the only thing out here that means "under way".
  final bool navigating;

  /// False in widget tests and on any build without the platform plugins, where
  /// the map would be a spinner and the location plugin is not answering.
  final bool enableNativeServices;

  /// Supplied by tests. Production builds their own over [DeviceLocationSource].
  final ForegroundLocationController? locationController;

  @override
  State<HomeMapBackdrop> createState() => _HomeMapBackdropState();
}

class _HomeMapBackdropState extends State<HomeMapBackdrop>
    with WidgetsBindingObserver {
  /// The caller's notifier when it supplied one, otherwise this widget's own.
  late final ValueNotifier<route_domain.GeoPoint?> _position =
      widget.position ?? ValueNotifier<route_domain.GeoPoint?>(null);
  late final bool _ownsPosition = widget.position == null;
  final ValueNotifier<MapNavigationPosition?> _navigationPosition =
      ValueNotifier<MapNavigationPosition?>(null);
  late final FreeRoamRideRecorder _freeRoamRideRecorder;
  SpokenGuidanceSpeaker? _spokenGuidance;
  final _spokenGuidanceKeys = <String>{};
  String? _guidanceManeuverIdentity;
  route_domain.GeoPoint? _passedManeuverPosition;
  route_domain.GeoPoint? _lastGuidanceManeuverPosition;
  ForegroundLocationController? _location;
  bool _ownsLocationController = false;
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    // Free roam had no lifecycle observer at all, so the recovery that exists
    // inside a ride did not exist outside one (#577).
    WidgetsBinding.instance.addObserver(this);
    _freeRoamRideRecorder = FreeRoamRideRecorder(
      localDisplayName: widget.localDisplayName,
    );
    // The recovery control is offered on whether this map can show the rider,
    // so it has to rebuild when that changes.
    _position.addListener(_handleLocationChanged);
    _location = widget.locationController;
    if (_location == null && widget.enableNativeServices) {
      _ownsLocationController = true;
      _location = ForegroundLocationController(
        DeviceLocationSource(),
        (sample) async => _acceptLocationSample(sample),
      );
    }
    if (widget.enableNativeServices && widget.spokenGuidance != null) {
      _spokenGuidance = SpokenGuidanceSpeaker(
        widget.spokenGuidance!.createEngine(),
      );
      widget.spokenGuidance!.addListener(_onSpokenGuidanceChanged);
      unawaited(_warmNaturalVoiceIfNeeded());
    }
    final location = _location;
    if (location != null) {
      location.addListener(_handleLocationChanged);
      // Resumes only if access was already granted, so opening the app shows
      // no prompt.
      location.resumeIfAuthorized();
    }
  }

  void _handleLocationChanged() {
    final sample = _location?.activeSample;
    if (sample != null &&
        _navigationPosition.value?.recordedAt != sample.recordedAt) {
      _acceptLocationSample(sample);
    }
    if (mounted) setState(() {});
  }

  /// Keeps the complete foreground fix for navigation while publishing the
  /// plain point Home uses for destination planning.
  ///
  /// Free roam used to discard speed, heading and accuracy here. The map could
  /// still place the bike, but every navigation instrument then saw no fix at
  /// all: live speed stayed at a dash, the posted limit could not move to the
  /// next road, and the marker stayed on its initial bearing (#655).
  void _acceptLocationSample(LocationSample sample) {
    final point = route_domain.GeoPoint(
      latitude: sample.position.latitude,
      longitude: sample.position.longitude,
      recordedAt: sample.recordedAt,
    );
    _navigationPosition.value = MapNavigationPosition(
      point: point,
      recordedAt: sample.recordedAt,
      speedMetersPerSecond: sample.speedMetersPerSecond,
      headingDegrees: sample.headingDegrees,
      accuracyMeters: sample.accuracyMeters,
    );
    _freeRoamRideRecorder.record(point);
    // Published second: `_position` also drives this State's listener, which
    // must see the matching navigation fix already installed rather than
    // recursively accepting the same native sample.
    _position.value = point;
  }

  void _onRouteChanged(route_domain.ImportedRoute? route) {
    if (route != null) {
      _freeRoamRideRecorder.start(route, initialPosition: _position.value);
      widget.onRouteChanged?.call(route);
      return;
    }
    final completed = _freeRoamRideRecorder.finish();
    widget.onRouteChanged?.call(null);
    if (completed != null) unawaited(_saveCompletedNavigation(completed));
  }

  Future<void> _saveCompletedNavigation(CompletedRide completed) async {
    final store = widget.completedRideStore;
    if (store == null) return;
    try {
      await store.save(completed);
      if (mounted) widget.onNavigationArchived?.call(completed);
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This navigation could not be saved to My rides.'),
        ),
      );
    }
  }

  void _onSpokenGuidanceChanged() {
    unawaited(_warmNaturalVoiceIfNeeded());
  }

  Future<void> _warmNaturalVoiceIfNeeded() async {
    final controller = widget.spokenGuidance;
    final speaker = _spokenGuidance;
    if (controller == null || speaker == null) return;
    final naturalEnabled =
        controller.naturalVoicePack.enabled &&
        controller.naturalVoicePack.modelDirectory != null;
    try {
      await speaker.warmUp(
        enabled: widget.navigating && controller.enabled && naturalEnabled,
      );
    } on Object catch (error, stackTrace) {
      assert(() {
        debugPrint(
          'Natural voice warm-up failed in free roam: $error\n$stackTrace',
        );
        return true;
      }());
    }
  }

  void _onNavigationGuidanceChanged(NavigationGuidance? guidance) {
    if (guidance == null || !widget.navigating) return;
    final speaker = _spokenGuidance;
    final controller = widget.spokenGuidance;
    if (speaker == null || controller == null) return;
    if (!spokenAudioAllows(controller.mode, SpokenAudioClass.navigation)) {
      return;
    }

    final identity = guidance.instruction.maneuver.identity;
    if (identity != _guidanceManeuverIdentity) {
      if (_guidanceManeuverIdentity != null) {
        _passedManeuverPosition = _lastGuidanceManeuverPosition;
      }
      _guidanceManeuverIdentity = identity;
    }
    _lastGuidanceManeuverPosition = guidance.instruction.maneuver.position;

    final passed = _passedManeuverPosition;
    final rider = _navigationPosition.value?.point;
    final metersSincePrevious = passed == null || rider == null
        ? null
        : GeoCalculations.distanceMeters(
            awareness_geo.GeoPoint(
              latitude: rider.latitude,
              longitude: rider.longitude,
            ),
            awareness_geo.GeoPoint(
              latitude: passed.latitude,
              longitude: passed.longitude,
            ),
          );
    final announcement = nextGuidanceAnnouncement(
      maneuverIdentity: identity,
      instructionText: guidance.instruction.standaloneText,
      distanceToManeuverMeters: guidance.distanceMeters,
      speedMetersPerSecond: _navigationPosition.value?.speedMetersPerSecond,
      alreadySpokenKeys: _spokenGuidanceKeys,
      metersSincePreviousManeuver: metersSincePrevious,
      distanceFormatter: MeasurementFormatter(widget.distanceUnit).distance,
      followingInstructionText: guidance.followingInstruction?.standaloneText,
    );
    if (announcement == null) return;
    _spokenGuidanceKeys.add(announcement.key);
    unawaited(
      speaker.speakManoeuvre(
        key: announcement.key,
        phrase: announcement.phrase,
        enabled: true,
        rideActive: widget.navigating,
      ),
    );
  }

  Future<void> _requestLocation() async {
    final location = _location;
    if (location == null || _requesting) return;
    setState(() => _requesting = true);
    try {
      await location.requestAndStart();
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  /// Restarts the sampler the way `ActiveRideShell` already does.
  ///
  /// iOS stops delivering foreground fixes across a background trip and does
  /// not say so; the subscription survives while the fixes do not. The ride
  /// shell has called this since #205. Free roam never did, which is why a
  /// rider who had been in and out of the app for a while came back to a map
  /// that no longer knew where they were (#577).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) return;
    unawaited(_location?.restartAfterForegroundResume());
  }

  @override
  void didUpdateWidget(covariant HomeMapBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.navigating && widget.navigating) {
      unawaited(_warmNaturalVoiceIfNeeded());
    } else if (oldWidget.navigating && !widget.navigating) {
      _spokenGuidanceKeys.clear();
      _guidanceManeuverIdentity = null;
      _passedManeuverPosition = null;
      _lastGuidanceManeuverPosition = null;
      _spokenGuidance?.reset();
      unawaited(_spokenGuidance?.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _position.removeListener(_handleLocationChanged);
    _location?.removeListener(_handleLocationChanged);
    widget.spokenGuidance?.removeListener(_onSpokenGuidanceChanged);
    unawaited(_spokenGuidance?.stop());
    if (_ownsLocationController) _location?.dispose();
    _navigationPosition.dispose();
    // Not ours to dispose when the screen above owns it.
    if (_ownsPosition) _position.dispose();
    super.dispose();
  }

  bool get _sharing => _location?.sharing ?? false;

  /// Whether to offer the rider a way to be found.
  ///
  /// It used to be `!_sharing` alone, which asks whether sampling was
  /// *requested* rather than whether it produced anything. A sampler that is
  /// running but has delivered no fix leaves the map with no rider on it and
  /// destination search refusing to start — and the one control that would
  /// have fixed it hidden, because `sharing` was true. Quitting and reopening
  /// the app was the only way back (#577).
  ///
  /// Deliberately *not* a staleness rule. The platform stream carries a 10 m
  /// distance filter, so a parked bike and a dead receiver produce the same
  /// silence — `device_location_source.dart` says so where the filter is set.
  /// Judging on whether there is a position to show needs no such guess: if
  /// the rider is on the map they are found, and if they are not they are
  /// offered the way to be.
  bool get _offerLocation => !_sharing || _position.value == null;

  @override
  Widget build(BuildContext context) {
    final chrome = widget.hostChrome;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.enableNativeServices)
          RideMapFeature.fromEnvironment(
            key: const Key('home-map'),
            currentPosition: _position,
            navigationPosition: _navigationPosition,
            completedRideStore: widget.completedRideStore,
            globalRideHeatmap: widget.globalRideHeatmap,
            darkMapStyle: widget.mapStyleMode.resolveDark(
              MediaQuery.platformBrightnessOf(context),
            ),
            restrainedLightMapStyle:
                widget.mapStyleMode.dayStyle == DayMapStyle.restrained,
            speedLimitDisplay: widget.speedLimitDisplay,
            distanceUnit: widget.distanceUnit,
            onMapStyleResolved: widget.onMapStyleResolved,
            hostChrome: chrome,
            // No ride, so no group route and no leader to defer to: a route
            // built here is this rider's own. This used to pass
            // `canEditRoute: false`, borrowing the flag that means "not the
            // leader", which refused a rider their own café stop in the name
            // of a group that did not exist (#576).
            routeAuthority: RouteAuthority.personal,
            pendingInAppRoute: widget.pendingInAppRoute,
            changeRouteRequestToken: widget.changeRouteRequestToken,
            onChangeRouteRequestHandled: widget.onChangeRouteRequestHandled,
            circularRideRequestToken: widget.circularRideRequestToken,
            onCircularRideRequestHandled: widget.onCircularRideRequestHandled,
            onRouteChanged: _onRouteChanged,
            onNavigationGuidanceChanged: _onNavigationGuidanceChanged,
            navigating: widget.navigating,
            markerFeaturesEnabled: false,
          )
        else
          // Widget tests and plugin-less builds. Named so a test can assert the
          // home screen is map-first without standing up a platform map.
          //
          // The chrome is drawn here too. It reaches riders through the map's
          // AppBar now, and a build with no platform map must not therefore
          // lose its search field and its way into Settings.
          Scaffold(
            appBar: chrome == null
                ? null
                : AppBar(
                    toolbarHeight: rideMapToolbarHeight(
                      landscape:
                          MediaQuery.orientationOf(context) ==
                          Orientation.landscape,
                    ),
                    titleSpacing: 12,
                    title: chrome.title,
                    actions: [
                      ...chrome.actions,
                      if (chrome.onMore != null)
                        IconButton(
                          key: const Key('home-more-actions'),
                          tooltip: 'More',
                          onPressed: chrome.onMore,
                          icon: const Icon(Icons.more_horiz),
                        ),
                    ],
                  ),
            body: const ColoredBox(
              key: Key('home-map-unavailable'),
              color: Color(0xFF141A22),
            ),
          ),
        if (_offerLocation)
          Positioned(
            right: 12,
            bottom: 12 + widget.bottomInset,
            child: SafeArea(
              child: FilledButton.tonalIcon(
                key: const Key('home-show-my-location'),
                onPressed: _location == null || _requesting
                    ? null
                    : _requestLocation,
                icon: const Icon(Icons.my_location),
                // Words, not a bare icon (#306).
                label: const Text('Show my location'),
              ),
            ),
          ),
      ],
    );
  }
}

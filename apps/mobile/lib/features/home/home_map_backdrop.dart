import 'dart:async';

import 'package:flutter/material.dart';

import '../../controllers/foreground_location_controller.dart';
import '../../controllers/global_ride_heatmap_controller.dart';
import '../../controllers/map_style_mode_controller.dart';
import '../../controllers/speed_limit_display_controller.dart';
import '../../domain/distance_unit.dart';
import '../../domain/completed_ride_store.dart';
import '../../domain/imported_route.dart' as route_domain;
import '../../domain/map_style_mode.dart';
import '../../services/device_location_source.dart';
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
    this.enableNativeServices = true,
    this.locationController,
    this.bottomInset = 0,
    this.position,
    this.completedRideStore,
    this.globalRideHeatmap,
    this.onMapStyleResolved,
  });

  /// Height kept clear at the bottom for whatever stands on the map.
  ///
  /// The home actions are a bar there now (#426), and the map's own location
  /// control has to sit above it rather than behind it.
  final double bottomInset;

  /// Where the rider is, published for the screen above to use.
  ///
  /// Supplied by [HomeScreen] so a searched destination can be routed from *here*
  /// without this widget owning a position nothing else can reach (#431). When
  /// absent it keeps its own, as it did before there was anything to tell.
  final ValueNotifier<route_domain.GeoPoint?>? position;

  final MapStyleModeController mapStyleMode;
  final SpeedLimitDisplayController speedLimitDisplay;
  final DistanceUnit distanceUnit;
  final CompletedRideStore? completedRideStore;
  final GlobalRideHeatmapController? globalRideHeatmap;
  final ValueChanged<String>? onMapStyleResolved;

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
  ForegroundLocationController? _location;
  bool _ownsLocationController = false;
  bool _requesting = false;

  @override
  void initState() {
    super.initState();
    // Free roam had no lifecycle observer at all, so the recovery that exists
    // inside a ride did not exist outside one (#577).
    WidgetsBinding.instance.addObserver(this);
    // The recovery control is offered on whether this map can show the rider,
    // so it has to rebuild when that changes.
    _position.addListener(_handleLocationChanged);
    _location = widget.locationController;
    if (_location == null && widget.enableNativeServices) {
      _ownsLocationController = true;
      _location = ForegroundLocationController(
        DeviceLocationSource(),
        (sample) async => _position.value = route_domain.GeoPoint(
          latitude: sample.position.latitude,
          longitude: sample.position.longitude,
          recordedAt: sample.recordedAt,
        ),
      );
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
    if (mounted) setState(() {});
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
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _position.removeListener(_handleLocationChanged);
    _location?.removeListener(_handleLocationChanged);
    if (_ownsLocationController) _location?.dispose();
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
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.enableNativeServices)
          RideMapFeature.fromEnvironment(
            key: const Key('home-map'),
            currentPosition: _position,
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
            // No ride yet, so nothing may edit a ride's route from here and no
            // ride surface has anything to say.
            canEditRoute: false,
            markerFeaturesEnabled: false,
          )
        else
          // Widget tests and plugin-less builds. Named so a test can assert the
          // home screen is map-first without standing up a platform map.
          const ColoredBox(
            key: Key('home-map-unavailable'),
            color: Color(0xFF141A22),
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

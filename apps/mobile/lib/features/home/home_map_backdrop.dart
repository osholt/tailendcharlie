import 'package:flutter/material.dart';

import '../../controllers/foreground_location_controller.dart';
import '../../controllers/map_style_mode_controller.dart';
import '../../controllers/speed_limit_display_controller.dart';
import '../../domain/distance_unit.dart';
import '../../domain/imported_route.dart' as route_domain;
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

  /// False in widget tests and on any build without the platform plugins, where
  /// the map would be a spinner and the location plugin is not answering.
  final bool enableNativeServices;

  /// Supplied by tests. Production builds their own over [DeviceLocationSource].
  final ForegroundLocationController? locationController;

  @override
  State<HomeMapBackdrop> createState() => _HomeMapBackdropState();
}

class _HomeMapBackdropState extends State<HomeMapBackdrop> {
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

  @override
  void dispose() {
    _location?.removeListener(_handleLocationChanged);
    if (_ownsLocationController) _location?.dispose();
    // Not ours to dispose when the screen above owns it.
    if (_ownsPosition) _position.dispose();
    super.dispose();
  }

  bool get _sharing => _location?.sharing ?? false;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.enableNativeServices)
          RideMapFeature.fromEnvironment(
            key: const Key('home-map'),
            currentPosition: _position,
            darkMapStyle: widget.mapStyleMode.resolveDark(
              MediaQuery.platformBrightnessOf(context),
            ),
            speedLimitDisplay: widget.speedLimitDisplay,
            distanceUnit: widget.distanceUnit,
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
        if (!_sharing)
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

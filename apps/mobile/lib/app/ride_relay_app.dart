import 'package:flutter/material.dart';

import '../controllers/distance_unit_controller.dart';
import '../controllers/completed_rides_controller.dart';
import '../controllers/map_style_mode_controller.dart';
import '../controllers/ride_code_preference_controller.dart';
import '../controllers/ride_controller.dart';
import '../controllers/rider_profile_controller.dart';
import '../controllers/shared_route_controller.dart';
import '../controllers/speed_limit_display_controller.dart';
import '../domain/recorded_route_store.dart';
import '../features/home/home_screen.dart';
import '../features/onboarding/onboarding_screen.dart';
import '../features/ride/active_ride_shell.dart';
import '../internet/plan_directory.dart';

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
    required this.recordedRoutes,
    required this.completedRides,
    this.planDirectory,
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
  final bool enableNativeServices;

  @override
  Widget build(BuildContext context) {
    const background = Color(0xFF0D1117);
    const surface = Color(0xFF171D25);
    const orange = Color(0xFFFF7A1A);

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
      home: AnimatedBuilder(
        animation: Listenable.merge([
          controller,
          distanceUnits,
          mapStyleMode,
          completedRides,
          sharedRoutes,
          riderProfile,
          speedLimitDisplay,
        ]),
        builder: (context, _) {
          if (controller.hasActiveRide) {
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
            recordedRoutes: recordedRoutes,
            completedRides: completedRides,
            planDirectory: planDirectory,
          );
        },
      ),
    );
  }
}

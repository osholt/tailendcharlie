/// Compile-time gate for ride diagnostics recording.
///
/// The recorder exists because four defects from the 10 August ride (#412, #409,
/// #418, #414) cannot be settled from a description: each needs what the app said
/// placed beside what the bike then did. Asking a rider to notice and remember
/// that at 60 mph does not work.
///
/// It writes down where a rider went, so it is gated the way the test-control
/// surface is (`docs/test-control-api.md`): this compile-time flag, plus an
/// explicit in-app switch that defaults to off and says in plain words what is
/// recorded. There is no third gate here because, unlike test control, nothing
/// reaches the phone from outside — the file goes nowhere until the rider picks a
/// recipient in the share sheet.
///
/// [enabled] is a `const` read of the environment specifically so a build without
/// the define tree-shakes the recorder out. An ordinary build cannot be talked
/// into recording by changing a setting, because the code is not there.
library;

class RideDiagnosticsConfiguration {
  const RideDiagnosticsConfiguration._();

  /// Compiled in only with `--dart-define=RIDE_RELAY_RIDE_DIAGNOSTICS=true`.
  static const bool enabled = bool.fromEnvironment(
    'RIDE_RELAY_RIDE_DIAGNOSTICS',
  );

  /// Bound on entries held in memory.
  ///
  /// A long ride must not be able to grow this without limit — the phone is also
  /// running navigation. Oldest entries are dropped first and the report says how
  /// many went, because a silently truncated record reads as a complete one.
  static const int maximumEntries = 4000;

  /// A normal ride must leave enough location evidence to diagnose a frozen
  /// speed, heading, or route without turning a three-hour ride into a
  /// once-per-second location dump. The first fix is always written; later
  /// fixes are sampled when either bound is crossed.
  static const Duration locationSampleInterval = Duration(seconds: 30);
  static const double locationSampleDistanceMeters = 500;

  /// How close to a manoeuvre a position sample must be to serve as the
  /// *approach* heading, and how far past it for the *departure* heading.
  ///
  /// The pair is what #412 turns on: the app derives a roundabout's direction
  /// from the engine's approach and exit bearings, and the question is whether
  /// those match the road the rider was actually on. Measured on the same side of
  /// the junction the engine measures, far enough out that the rider is on the
  /// road rather than in the junction.
  static const double headingSampleMeters = 40.0;

  /// Past this, a sample is too far from the junction to describe it.
  static const double headingSampleToleranceMeters = 35.0;
}

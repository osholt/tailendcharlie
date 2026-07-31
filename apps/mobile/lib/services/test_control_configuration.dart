/// Compile-time gate for the test-control surface.
///
/// The surface exists so field-test sequences in `docs/field-test-plan.md` can be
/// driven and measured without a person tapping two phones in sync. It is a
/// remote-control API for a safety application, so it is gated three times over:
/// this compile-time flag, an explicit in-app toggle that defaults to off, and a
/// bearer token regenerated every time the toggle is turned on.
///
/// [enabled] is a `const` read of the environment specifically so that a build
/// without the define tree-shakes the server, its routes and its snapshot
/// assembly out of the binary entirely. A release build cannot be talked into
/// serving this by changing a setting, because the code is not there.
library;

class TestControlConfiguration {
  const TestControlConfiguration({
    this.port = defaultPort,
    this.idleTimeout = defaultIdleTimeout,
  });

  /// Compiled in only with `--dart-define=RIDE_RELAY_TEST_CONTROL=true`.
  ///
  /// Deliberately not `RIDE_RELAY_`-prefixed-and-forgotten: the name appears in
  /// **About & build** when it is on, because a build that can be driven
  /// remotely should say so rather than look like an ordinary build.
  static const bool enabled = bool.fromEnvironment('RIDE_RELAY_TEST_CONTROL');

  /// Fixed so tooling does not have to discover it. Above the privileged range
  /// and outside the ephemeral range on both platforms.
  static const int defaultPort = 8477;

  /// The toggle turns itself off after this long with no authenticated request.
  /// A phone left on a bench with an open control port is the failure this
  /// guards against - the person who enabled it for a twenty-minute test is not
  /// going to remember to switch it off before riding.
  static const Duration defaultIdleTimeout = Duration(minutes: 30);

  final int port;
  final Duration idleTimeout;
}

/// Actions the test-control surface will never expose, and why.
///
/// This is not a to-do list. Each of these reaches outside the app to a person
/// or a phone network, and an automation surface that can trigger one is worth
/// less than the harm of it firing by accident or by a stranger on the same
/// Wi-Fi:
///
/// - **SOS and emergency actions.** The point of an emergency control is that a
///   human meant it.
/// - **Emergency-contact and ICE disclosure.** Someone else's data.
/// - **Sharing a rider's own phone number.** Same.
/// - **Placing calls or sending messages** through the platform handoffs.
///
/// If any of these ever needs test coverage it belongs in a widget or
/// integration test against a fake, not behind a network port on a real phone.
/// Tested by `test/services/test_control_server_test.dart`.
const Set<String> testControlForbiddenActions = {
  'sos',
  'emergency',
  'ice',
  'contact-share',
  'call',
  'message-send',
};

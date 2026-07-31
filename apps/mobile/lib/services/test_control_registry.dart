import '../controllers/situational_awareness_controller.dart';

/// Where the active ride publishes its situational-awareness controller so the
/// test-control surface can reach it.
///
/// The surface is started once at launch, but
/// [SituationalAwarenessController] is created per ride inside `ActiveRideShell`
/// and replaced whenever the route changes. A direct reference captured at
/// startup would be null forever; a reference captured once would go stale on the
/// first route publish and then drive a disposed controller.
///
/// So the shell owns the lifetime and this holds only the current one. An absent
/// controller is the ordinary state - no ride is active - and the surface answers
/// those requests with a conflict rather than pretending.
class TestControlRegistry {
  SituationalAwarenessController? _awareness;

  SituationalAwarenessController? get awareness => _awareness;

  void publish(SituationalAwarenessController controller) {
    _awareness = controller;
  }

  /// Clears [controller] if it is still the published one. Passing the specific
  /// controller matters: the shell disposes the outgoing controller *after*
  /// publishing its replacement on a route change, and an unconditional clear
  /// would blank the live one.
  void withdraw(SituationalAwarenessController controller) {
    if (_awareness == controller) _awareness = null;
  }
}

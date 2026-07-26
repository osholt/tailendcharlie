import 'ride_event.dart';

enum QuickMessage {
  stopped,
  mechanical,
  fuel,
  assistance,
  routeBlocked,
  emergencyStop,
  allPassed,
  resolved,
}

extension QuickMessageDetails on QuickMessage {
  String get label => switch (this) {
    QuickMessage.stopped => 'Stopped',
    QuickMessage.mechanical => 'Mechanical',
    QuickMessage.fuel => 'Need fuel',
    QuickMessage.assistance => 'Need help',
    QuickMessage.routeBlocked => 'Route blocked',
    QuickMessage.emergencyStop => 'Emergency stop',
    QuickMessage.allPassed => 'All riders passed',
    QuickMessage.resolved => 'Resolved',
  };

  EventPriority get priority => switch (this) {
    QuickMessage.emergencyStop ||
    QuickMessage.assistance => EventPriority.critical,
    QuickMessage.mechanical ||
    QuickMessage.routeBlocked => EventPriority.important,
    _ => EventPriority.routine,
  };

  /// What a rider raising this needs the group to be told, as a sentence naming
  /// them.
  ///
  /// A received alert has to say "Bill needs fuel", not "a status message
  /// arrived" (#151), and the sender's own [label] is the wrong half of that
  /// sentence — it is written for the button they pressed, not for the rider
  /// reading it on another phone.
  String sentenceFor(String riderName) => switch (this) {
    QuickMessage.stopped => '$riderName has stopped',
    QuickMessage.mechanical => '$riderName has a mechanical problem',
    QuickMessage.fuel => '$riderName needs fuel',
    QuickMessage.assistance => '$riderName needs help',
    QuickMessage.routeBlocked => '$riderName says the route is blocked',
    QuickMessage.emergencyStop => '$riderName has made an emergency stop',
    QuickMessage.allPassed => '$riderName says all riders have passed',
    QuickMessage.resolved => '$riderName says it is resolved',
  };

  /// Whether raising this retires the sender's earlier outstanding messages.
  ///
  /// "Resolved" is the rider saying the thing they raised is dealt with, so it
  /// must clear their own card rather than adding a second one to it.
  bool get retiresEarlierMessages => this == QuickMessage.resolved;
}

/// The [QuickMessage] a relayed payload names, or null when this build does not
/// know it.
///
/// A newer build can raise a kind this one has never heard of. The relayed
/// event still carries the sender's own `label`, so the message is presented
/// with what the sender called it rather than being dropped — the same
/// forwards-compatibility rule `relay_event_compatibility.dart` applies to
/// whole events.
QuickMessage? tryParseQuickMessage(Object? name) {
  if (name is! String) return null;
  for (final candidate in QuickMessage.values) {
    if (candidate.name == name) return candidate;
  }
  return null;
}

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

  // The leader's one-tap broadcasts to the group (#854). Appended, never
  // reordered, and sent as ordinary `statusMessage` events: an older build that
  // does not know a name shows the sender's own `label` (see [tryParseQuickMessage]),
  // so a mixed group still reads "Oliver: Pull over".

  /// "Wrong way - turn around".
  wrongWay,

  /// "Stopped for fuel": the leader has stopped, and why. Not [fuel], which is a
  /// rider saying *they* need it.
  stoppedForFuel,

  /// "Pull over".
  pullOver,

  /// "Regroup at next stop".
  regroupNextStop,
}

/// The leader's broadcasts, in the order the map offers them (#854).
const leaderBroadcastMessages = <QuickMessage>[
  QuickMessage.wrongWay,
  QuickMessage.stoppedForFuel,
  QuickMessage.pullOver,
  QuickMessage.regroupNextStop,
];

/// How long a broadcast stays worth showing.
///
/// Ten minutes, not the two hours of a rider's own message: "Pull over" and
/// "Wrong way" are about where the group is now, and a banner that outlived its
/// moment would send a rider who had since regrouped back to look for it.
const leaderBroadcastLife = Duration(minutes: 10);

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
    QuickMessage.wrongWay => 'Wrong way – turn around',
    QuickMessage.stoppedForFuel => 'Stopped for fuel',
    QuickMessage.pullOver => 'Pull over',
    QuickMessage.regroupNextStop => 'Regroup at next stop',
  };

  EventPriority get priority => switch (this) {
    QuickMessage.emergencyStop ||
    QuickMessage.assistance => EventPriority.critical,
    // Instructions and news from the leader are pressing, not an emergency: they
    // take the alert palette and are read out, but never blank the map (#854).
    QuickMessage.mechanical ||
    QuickMessage.routeBlocked ||
    QuickMessage.wrongWay ||
    QuickMessage.stoppedForFuel ||
    QuickMessage.pullOver ||
    QuickMessage.regroupNextStop => EventPriority.important,
    _ => EventPriority.routine,
  };

  /// Whether this is one of the leader's broadcasts to the group (#854).
  ///
  /// Only the leader may send these: the map offers them to nobody else and a
  /// receiving phone discards one from anybody who was not the leader at that
  /// point in the ride, as it does a forged ride start or Tail End Charlie request.
  bool get isLeaderBroadcast => leaderBroadcastMessages.contains(this);

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
    QuickMessage.wrongWay => '$riderName says wrong way, turn around',
    QuickMessage.stoppedForFuel => '$riderName has stopped for fuel',
    QuickMessage.pullOver => '$riderName says pull over',
    QuickMessage.regroupNextStop => '$riderName says regroup at the next stop',
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

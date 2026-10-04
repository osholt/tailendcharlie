import '../domain/quick_message.dart';
import '../domain/ride_coordination_mode.dart';
import 'received_quick_message.dart';

/// Whether the leader's one-tap broadcasts are offered on the ride map (#854).
///
/// A pure function of four facts, so the rule can be read and tested without a
/// ride shell:
///
/// * **the leader, and only the leader.** Telling the group where to go is the
///   leader's job and nobody else's; a rider offered "Pull over" would be a rider
///   able to stop a group. [isLocalRideLeader] counts a leader who is acting as a
///   junction marker, because that is still the person at the front.
/// * **a running ride.** Before the start nobody is riding to be told anything, and
///   after the end nobody is listening.
/// * **a group.** A solo ride has nobody to tell.
///
/// A paused ride is deliberately allowed: "Regroup at next stop" is most useful
/// exactly when the group has stopped.
bool leaderBroadcastsAvailable({
  required bool isLocalRideLeader,
  required bool rideStarted,
  required bool rideEnded,
  required RideCoordinationMode coordinationMode,
}) =>
    isLocalRideLeader &&
    rideStarted &&
    !rideEnded &&
    coordinationMode != RideCoordinationMode.solo;

/// How long the leader's own double tap is one broadcast.
///
/// The same reason an alert has a cooldown (#849): one tap on a big target in
/// gloves can bounce, and a bounce must not read as the leader insisting. A
/// *different* broadcast is never held back, and the same one a few seconds later
/// is a deliberate repeat - "Pull over" said twice is the leader saying it twice.
const leaderBroadcastBounceWindow = Duration(seconds: 4);

/// A broadcast older than this is not read aloud.
///
/// Two minutes. It is shown, and stays shown until acknowledged or expired, but a
/// phone that restarts mid-ride rebuilds its messages from the journal and would
/// otherwise say a ten-minute-old "Pull over" again as though it were new: the
/// same instruction delivered twice. A rider who was out of signal for longer than
/// this still sees the banner; they are not told aloud about the past.
const leaderBroadcastSpeechFreshness = Duration(minutes: 2);

/// A little forward clock skew is allowed before a message reads as "from the
/// future" and is held back, because two phones' clocks are never the same.
const _clockSkewAllowance = Duration(minutes: 2);

/// What the natural voice says when a leader's broadcast reaches this phone, or
/// null when it must not be said.
///
/// Null for: anything that is not a leader broadcast, the rider's own (nobody needs
/// their own message read back), and one that is no longer fresh - see
/// [leaderBroadcastSpeechFreshness]. The speaking path adds the once-only guard,
/// keyed by [leaderBroadcastSpeechKey], so the same event arriving over the relay
/// and over Nearby, or being rebuilt from the journal, is said once.
String? leaderBroadcastSpeech({
  required ReceivedQuickMessage message,
  required DateTime now,
}) {
  final kind = message.message;
  if (kind == null || !kind.isLeaderBroadcast) return null;
  if (message.raisedFromLocalRider) return null;
  final age = now.difference(message.raisedAt);
  if (age > leaderBroadcastSpeechFreshness) return null;
  if (age < -_clockSkewAllowance) return null;
  return '${kind.sentenceFor(spokenRiderName(message.senderDisplayName))}.';
}

/// Everything the voice should say now, one entry per journal event.
///
/// Takes the banners the map is showing and looks inside each one: a banner stands
/// for every repeat of the same words from the same leader, and each repeat is its
/// own journal event with its own key, so a leader who says "Pull over" twice
/// because nobody has is heard twice. The caller hands each entry to the speech
/// engine, whose once-only memory makes asking again on the next fix harmless.
List<({String key, String phrase})> leaderBroadcastsToSpeak({
  required Iterable<RideQuickMessageAlert> alerts,
  required DateTime now,
}) => [
  for (final alert in alerts)
    for (final message in alert.acknowledgeable)
      if (leaderBroadcastSpeech(message: message, now: now) case final phrase?)
        (key: leaderBroadcastSpeechKey(message), phrase: phrase),
];

/// The identity of one broadcast for the speech engine's once-only memory: the
/// journal event, so two copies of one event are one broadcast.
String leaderBroadcastSpeechKey(ReceivedQuickMessage message) =>
    'leader-broadcast:${message.eventId}';

/// A display name made safe to say.
///
/// A name is typed by a rider and relayed by a phone, and goes into a sentence the
/// speech engine reads whole. Anything that is not a letter (accents included), a
/// digit or ordinary name punctuation is dropped, runs of space collapse, and the
/// result is bounded,
/// so a name cannot lengthen a safety instruction or smuggle in something to be
/// read out. Empty after that, it is "Your leader": the only person who can have
/// said it.
String spokenRiderName(String name, {int maximumLength = 24}) {
  final cleaned = name
      .replaceAll(RegExp(r"[^\p{L}\p{M}\p{N} '’.-]", unicode: true), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (cleaned.isEmpty) return 'Your leader';
  final bounded = String.fromCharCodes(
    cleaned.runes.take(maximumLength),
  ).trim();
  return bounded.isEmpty ? 'Your leader' : bounded;
}

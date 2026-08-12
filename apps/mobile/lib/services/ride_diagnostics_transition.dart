/// What to do to the recorder when the diagnostics switch moves (#457).
///
/// ## What was wrong
///
/// The recorder was built in the ride shell's `initState` and nowhere else, and
/// nothing listened to the controller afterwards. So the switch was read **once**,
/// when the ride screen was first built, and never again.
///
/// The consequence for a rider: reaching Settings through the *ride menu* — the
/// door closest to hand once you are already riding — turned recording on, showed
/// it on, and recorded nothing for the rest of that ride. The switch lied about
/// what it was doing.
///
/// It is also the more likely way to arrive at it. A rider decides to record
/// *because* something has just gone wrong, and by then they are mid-ride.
///
/// ## Why this is a function and not an `if` in the shell
///
/// No widget test in this repo constructs `ActiveRideShell` — it needs a session, a
/// relay, a location stream and a map — so an `if` inside the state class is
/// reachable only by riding. Every interesting case lives in the three booleans
/// below, so they are lifted out and enumerated in a test instead.
library;

/// The action to take on the recorder.
enum RideDiagnosticsTransition {
  /// No recorder yet: build one, and say in the log that the ride was already
  /// under way so a reader is not misled into thinking the earlier part was quiet
  /// rather than unrecorded.
  start,

  /// A recorder exists but was stopped: take it up again, keeping its entries.
  resume,

  /// Stop accepting entries and write out what there is.
  stop,

  /// Already in the asked-for state.
  nothing,
}

/// The transition implied by [switchedOn], given what the shell currently holds.
///
/// [hasRecorder] and [isRecording] are separate because they are separately
/// reachable: no recorder at all is the state a ride starts in with the switch
/// off, while a stopped recorder holding entries is what switching off mid-ride
/// leaves behind.
RideDiagnosticsTransition rideDiagnosticsTransition({
  required bool switchedOn,
  required bool hasRecorder,
  required bool isRecording,
}) {
  if (switchedOn) {
    if (!hasRecorder) return RideDiagnosticsTransition.start;
    return isRecording
        ? RideDiagnosticsTransition.nothing
        : RideDiagnosticsTransition.resume;
  }
  if (!hasRecorder) return RideDiagnosticsTransition.nothing;
  return isRecording
      ? RideDiagnosticsTransition.stop
      : RideDiagnosticsTransition.nothing;
}

/// The note a recorder built mid-ride opens with.
///
/// Says what is *missing*, not just when it started. A log that begins in the
/// middle of a ride and does not say so reads as a record of the whole ride with a
/// quiet first half.
const rideDiagnosticsStartedMidRideNote =
    'recording started mid-ride — nothing before this point was recorded';

/// The note a recorder built at the start of a ride opens with.
const rideDiagnosticsStartedNote = 'recording started';

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/geo_point.dart';
import '../domain/rider_location.dart';
import '../services/geo_calculations.dart';
import '../services/sharing_dispersal.dart';

/// Where a rider's location sharing stands.
enum SharingGuardPhase {
  /// Sharing, and nothing to ask.
  sharing,

  /// Still sharing, and the rider has been asked whether they are still riding.
  /// Nothing has been decided: sharing carries on until it is answered or the
  /// countdown runs out.
  prompting,

  /// This phone is no longer publishing the rider's position. The ride is not
  /// ended and the rider has not left it.
  paused,
}

/// Why sharing was paused, which decides what the rider is told.
enum SharingPauseReason {
  /// The rider chose it.
  rider,

  /// The rider was asked and did not answer, so sharing stopped on its own.
  unanswered,
}

/// Decides when a phone that has been left running should stop sharing (#859),
/// and carries the question through to its end.
///
/// The judgement of a single moment lives in [assessDispersal]. This owns what a
/// moment cannot know: how long a verdict has held, whether the rider has been
/// asked, whether they have answered, and whether they are parked. It is driven
/// by [observeFix] for every device fix and [evaluate] on a timer, and it takes
/// its clock as a parameter so every transition can be tested without waiting.
///
/// The sequence:
///
///  1. The rider is judged [DispersalState.dispersed] continuously for
///     [SharingDispersalPolicy.promptAfter]: **prompting** begins.
///  2. If the group comes back, or anything else says the rider is riding again,
///     the question is withdrawn.
///  3. If it is answered, either sharing carries on and the question is held off
///     for [SharingDispersalPolicy.keepSharingSnooze], or sharing **pauses**.
///  4. If it is not, sharing pauses [SharingDispersalPolicy.answerWithin] after
///     the rider has stopped moving (or after the question, if that is later).
///     The countdown restarts whenever the rider moves: a rider on the road
///     cannot answer, and an unanswered question is not a refusal.
///
/// Pausing is not ending. The ride, its journal and the rider's membership are
/// untouched; the rider can resume with one tap.
class LocationSharingGuard extends ChangeNotifier {
  LocationSharingGuard({
    required this._onPause,
    required this._onResume,
    this.policy = const SharingDispersalPolicy(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final SharingDispersalPolicy policy;
  final DateTime Function() _clock;

  /// Stops this phone publishing the rider's position. Called once per pause,
  /// after [phase] has already changed, so a fix arriving while it runs is
  /// already refused.
  final Future<void> Function(SharingPauseReason reason) _onPause;

  /// Starts publishing again. Returns false when it could not - location
  /// permission removed, say - in which case the guard stays paused rather than
  /// claiming a sharing that is not happening.
  final Future<bool> Function() _onResume;

  SharingGuardPhase _phase = SharingGuardPhase.sharing;
  SharingPauseReason? _pauseReason;
  DateTime? _dispersedSince;
  DateTime? _snoozedUntil;
  DateTime? _promptedAt;
  DateTime? _answerWindowStart;
  DateTime? _pausedAt;
  DateTime? _lastEvaluatedAt;
  DispersalState? _lastState;
  LocationSample? _lastFix;
  _Anchor? _anchor;
  bool _evaluating = false;
  bool _resuming = false;
  bool _disposed = false;

  SharingGuardPhase get phase => _phase;

  /// True once sharing has been paused. The one question every publisher asks
  /// before sending a position.
  bool get isPaused => _phase == SharingGuardPhase.paused;

  /// Why sharing is paused, or null while it is not.
  SharingPauseReason? get pauseReason => _pauseReason;

  /// When the rider was first asked, while the question is up.
  DateTime? get promptedAt => _promptedAt;

  /// When an unanswered question will stop sharing, if the rider stays where
  /// they are. Pushed back whenever they move; null unless a question is up.
  DateTime? get promptDeadline {
    final start = _answerWindowStart;
    if (start == null) return null;
    final parkedSince = _anchor?.since;
    final from = parkedSince != null && parkedSince.isAfter(start)
        ? parkedSince
        : start;
    return from.add(policy.answerWithin);
  }

  DateTime? get pausedAt => _pausedAt;

  /// The most recent verdict, for the diagnostics log.
  DispersalState? get lastState => _lastState;

  /// How long the rider has been judged dispersed without a break.
  Duration? get dispersedFor {
    final since = _dispersedSince;
    return since == null ? null : _clock().difference(since);
  }

  /// How long the rider has stayed in one place. Zero while they move.
  Duration get parkedFor {
    final anchor = _anchor;
    if (anchor == null) return Duration.zero;
    final elapsed = _clock().difference(anchor.since);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  /// True when the rider has moved lately, as opposed to being parked. Only used
  /// to word the question honestly; see [SharingDispersalPolicy.ridingWindow].
  bool get movedRecently => _anchor != null && parkedFor < policy.ridingWindow;

  /// Takes every device fix, including those the position-report gate withholds:
  /// a rider who is not moving is exactly a rider who produces few of them.
  ///
  /// Movement has to clear the parked radius **plus the fix's own error**, so a
  /// poor fix on a phone sitting on a desk cannot read as the rider leaving.
  void observeFix(LocationSample sample) {
    if (_disposed) return;
    _lastFix = sample;
    final anchor = _anchor;
    if (anchor == null) {
      _anchor = _Anchor(sample.position, _clock());
      return;
    }
    final moved = GeoCalculations.distanceMeters(
      anchor.position,
      sample.position,
    );
    if (moved > policy.parkedRadiusMeters + sample.accuracyMeters) {
      _anchor = _Anchor(sample.position, _clock());
    }
  }

  /// One evaluation of the ride around this rider. Called every half minute
  /// while the ride is running; does nothing once sharing is paused.
  Future<void> evaluate({
    required bool groupRide,
    required List<DispersalPeer> peers,
    required bool peersObservable,
    DispersalRoute? route,
    DispersalMarkerWait? marker,
    DateTime? ridePausedAt,
  }) async {
    if (_disposed || _evaluating) return;
    _evaluating = true;
    try {
      final now = _clock();
      final previous = _lastEvaluatedAt;
      _lastEvaluatedAt = now;
      if (previous != null && now.difference(previous) > policy.continuityGap) {
        // The app was suspended or blocked. Nobody can say what the group did
        // in the gap, so "away for 30 minutes" starts again, and a question
        // that was up gets a fresh answer window: not having been reachable is
        // not the same as having declined.
        _dispersedSince = null;
        if (_phase == SharingGuardPhase.prompting) _answerWindowStart = now;
      }
      if (_phase == SharingGuardPhase.paused) return;

      final assessment = assessDispersal(
        DispersalInput(
          now: now,
          groupRide: groupRide,
          local: _lastFix,
          localParkedFor: parkedFor,
          peers: peers,
          peersObservable: peersObservable,
          route: route,
          marker: marker,
          ridePausedAt: ridePausedAt,
        ),
        policy: policy,
      );
      _lastState = assessment.state;

      if (!assessment.dispersed) {
        _dispersedSince = null;
        if (_phase == SharingGuardPhase.prompting) {
          // Back with the group, back on the route, or no longer able to tell:
          // the question no longer applies.
          _phase = SharingGuardPhase.sharing;
          _promptedAt = null;
          _answerWindowStart = null;
          _notify();
        }
        return;
      }

      final since = _dispersedSince ??= now;
      if (_phase == SharingGuardPhase.sharing) {
        final snoozedUntil = _snoozedUntil;
        final snoozed = snoozedUntil != null && now.isBefore(snoozedUntil);
        if (!snoozed && now.difference(since) >= policy.promptAfter) {
          _phase = SharingGuardPhase.prompting;
          _promptedAt = now;
          _answerWindowStart = now;
          _notify();
        }
        return;
      }

      // Prompting. A moving rider keeps pushing the deadline away, so only a
      // rider who has stopped can run out of time.
      final deadline = promptDeadline;
      if (deadline != null && !now.isBefore(deadline)) {
        await _pause(SharingPauseReason.unanswered);
      }
    } finally {
      _evaluating = false;
    }
  }

  /// "Keep sharing": the rider is still riding. Holds the question off for
  /// [SharingDispersalPolicy.keepSharingSnooze].
  void keepSharing() {
    if (_disposed || _phase != SharingGuardPhase.prompting) return;
    _phase = SharingGuardPhase.sharing;
    _promptedAt = null;
    _answerWindowStart = null;
    _snoozedUntil = _clock().add(policy.keepSharingSnooze);
    _notify();
  }

  /// "Stop sharing": the rider's own choice, from the question or from anywhere
  /// else they can reach it.
  Future<void> stopSharing() => _pause(SharingPauseReason.rider);

  /// Starts sharing again. Returns whether it did.
  ///
  /// Resuming is a statement that the rider wants to be seen, so it is treated
  /// like "keep sharing": the question is held off for the same two hours.
  Future<bool> resume() async {
    // A second tap while the first is still starting the location stream must
    // not start it twice.
    if (_disposed || _resuming || _phase != SharingGuardPhase.paused) {
      return false;
    }
    _resuming = true;
    try {
      final started = await _onResume();
      if (_disposed) return false;
      if (!started) {
        _notify();
        return false;
      }
      _phase = SharingGuardPhase.sharing;
      _pauseReason = null;
      _pausedAt = null;
      _dispersedSince = null;
      _snoozedUntil = _clock().add(policy.keepSharingSnooze);
      _notify();
      return true;
    } finally {
      _resuming = false;
    }
  }

  Future<void> _pause(SharingPauseReason reason) async {
    if (_disposed || _phase == SharingGuardPhase.paused) return;
    _phase = SharingGuardPhase.paused;
    _pauseReason = reason;
    _pausedAt = _clock();
    _promptedAt = null;
    _answerWindowStart = null;
    _dispersedSince = null;
    _notify();
    await _onPause(reason);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}

class _Anchor {
  const _Anchor(this.position, this.since);

  final GeoPoint position;
  final DateTime since;
}

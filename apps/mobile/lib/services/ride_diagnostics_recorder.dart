import '../domain/geo_point.dart';
import '../internet/internet_relay_worker.dart' show InternetRelayPhase;
import '../relay/relay_engine.dart' show RelayConnectionState, RelayStatus;
import 'geo_calculations.dart';
import 'ride_diagnostics_configuration.dart';
import 'spoken_guidance.dart';
import 'transport_evidence_ledger.dart';
import 'transport_evidence_presentation.dart' show formatEvidenceAge;

/// What the app said, beside what the bike then did.
///
/// The recorder holds a flat, ordered log of typed entries and renders them as
/// plain text for the end-of-ride share. Plain text on purpose: the reader is a
/// person comparing an instruction against a junction they remember, and the
/// existing per-manoeuvre sheet (#302) already proved that shape readable.
///
/// It is deliberately free of Flutter and of the ride shell, so the pairing
/// logic — the part that answers #412 — can be driven by a synthetic track in a
/// unit test rather than only by riding.
///
/// **Positions in here are the local rider's own.** Other riders' positions are
/// someone else's data and are never recorded; see #419.
///
/// **Other riders are not named either.** The `TRANSPORT` lines (#855) describe
/// how updates reached this phone — the direct link's state, peers appearing and
/// dropping, the ride service answering or failing, and a once-a-minute tally of
/// what each route delivered. Peers are "phone A", "phone B" in the order they
/// were first seen; no rider name, endpoint name or raw endpoint id is written,
/// and any that turns up inside a platform message is replaced before it is.
class RideDiagnosticsRecorder {
  RideDiagnosticsRecorder({
    DateTime Function()? clock,
    this.onEntry,
    this.privateTerms,
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// Names that must never reach the log — this rider's own display name and the
  /// other riders' — read each time free text is about to be written, so a rider
  /// who joins mid-ride is covered too. Used only to scrub platform messages
  /// that might echo one back; nothing here is ever written itself.
  final Iterable<String> Function()? privateTerms;

  /// Called after each entry, so a log on disk can be kept in step without the
  /// recorder knowing what a file is (#456). Still no filesystem in here: the
  /// pairing logic stays drivable by a synthetic track in a unit test.
  final void Function()? onEntry;
  final List<String> _entries = [];
  final List<_PositionSample> _recentPositions = [];
  _PositionSample? _lastWrittenPosition;

  /// Manoeuvres seen but not yet passed, keyed by the identity the guidance layer
  /// uses, so a manoeuvre re-derived on every position fix is not logged twice.
  final Map<String, _PendingManoeuvre> _pending = {};

  int _dropped = 0;
  bool _recording = true;

  // Transport evidence (#855). What was last written, so only a *change* is.
  final PeerAnonymiser _peers = PeerAnonymiser();
  Set<String> _nearbyPeerIds = const {};
  RelayConnectionState? _nearbyState;
  String? _nearbyProblem;
  bool? _internetSucceeding;
  int _internetFailureStreak = 0;
  DateTime? _internetFailingSince;
  DateTime? _nextTransportSummaryAt;
  TransportEvidenceSummary? _lastTransportSummary;

  /// Entries recorded, oldest first. Exposed for tests and for the report.
  List<String> get entries => List.unmodifiable(_entries);

  /// How many entries were dropped to stay inside the bound.
  int get droppedEntries => _dropped;

  bool get isEmpty => _entries.isEmpty;

  /// Whether new entries are being accepted (#457).
  bool get isRecording => _recording;

  /// Stops accepting entries, keeping everything already gathered.
  ///
  /// Separate from discarding the recorder because a rider who switches recording
  /// off mid-ride has not asked to throw away what was already captured — quite
  /// the opposite, usually: they have seen the thing they were recording for.
  void stopRecording() {
    if (!_recording) return;
    // Noted before the flag, or the note itself would be dropped.
    _add('NOTE       recording stopped');
    _recording = false;
  }

  /// Starts accepting entries again, saying so in the log.
  void resumeRecording() {
    if (_recording) return;
    _recording = true;
    _add('NOTE       recording resumed');
    // Whatever the links did while recording was off was not written, so the
    // next observation must state where they are now rather than assume the
    // last thing written still holds.
    _nearbyState = null;
    _nearbyProblem = null;
    _nearbyPeerIds = const {};
    _internetSucceeding = null;
  }

  void _add(String line) {
    if (!_recording) return;
    _entries.add('${_stamp()}  $line');
    // Drop from the front: the end of a ride is where the rider was when they
    // noticed something, so the newest entries are the ones worth keeping.
    while (_entries.length > RideDiagnosticsConfiguration.maximumEntries) {
      _entries.removeAt(0);
      _dropped += 1;
    }
    onEntry?.call();
  }

  String _stamp() => _clock().toUtc().toIso8601String();

  /// A position fix from the local rider.
  ///
  /// Kept in a short buffer rather than logged: a fix every second for a
  /// three-hour ride is ten thousand lines of nothing, and what matters is the
  /// two of them either side of each junction.
  void observePosition({
    required GeoPoint point,
    required double? headingDegrees,
    DateTime? recordedAt,
    double? speedMetersPerSecond,
    double? accuracyMeters,
  }) {
    if (!_recording) return;
    final sample = _PositionSample(
      point: point,
      headingDegrees: headingDegrees,
      recordedAt: recordedAt ?? _clock(),
    );
    _recentPositions.add(sample);
    // Enough to reach back past a junction at speed, and no more.
    if (_recentPositions.length > 240) _recentPositions.removeAt(0);
    if (_shouldWritePosition(sample)) {
      _lastWrittenPosition = sample;
      _add(
        'LOCATION   ${_coordinate(point)}  '
        'heading ${_degrees(headingDegrees)}  '
        'speed ${_metersPerSecond(speedMetersPerSecond)}  '
        'accuracy ${_meters(accuracyMeters)}',
      );
    }
    _resolvePassedManoeuvres();
  }

  bool _shouldWritePosition(_PositionSample sample) {
    final previous = _lastWrittenPosition;
    if (previous == null) return true;
    final elapsed = sample.recordedAt.difference(previous.recordedAt);
    if (!elapsed.isNegative &&
        elapsed >= RideDiagnosticsConfiguration.locationSampleInterval) {
      return true;
    }
    return GeoCalculations.distanceMeters(previous.point, sample.point) >=
        RideDiagnosticsConfiguration.locationSampleDistanceMeters;
  }

  /// The app has decided this is the manoeuvre the rider is riding towards.
  ///
  /// [diagnostics] is the report `maneuverDiagnosticsReport` already produces for
  /// the #302 turn-detail sheet, passed in rather than re-derived. That matters
  /// more than it looks: a roundabout's heading change is read across two merged
  /// steps and *not* from the entry manoeuvre's own `bearingAfter` (#360), so a
  /// second derivation here would be subtly different from the one the rider can
  /// see on screen — and an instrument that disagrees with the app it is
  /// measuring is worse than none.
  void recordManoeuvre({
    required String key,
    required GeoPoint position,
    required String shownAs,
    required String diagnostics,
  }) {
    // The key must be the manoeuvre's identity, not the source text that would
    // have produced it. Shipped once as a `\$`-escaped interpolation, which made
    // every manoeuvre share one key: the first was recorded and every later one
    // was silently treated as a repeat, so a whole ride produced one entry. The
    // analyzer cannot see that — it is a valid string — so the check is here.
    assert(!key.contains(r'$'), 'the manoeuvre key was not interpolated: $key');
    if (_pending.containsKey(key)) return;
    final indented = diagnostics
        .split('\n')
        .map((line) => '           $line')
        .join('\n');
    _add('MANOEUVRE  at ${_coordinate(position)}\n$indented');
    _pending[key] = _PendingManoeuvre(
      key: key,
      position: position,
      shownAs: shownAs,
      approachHeading: _headingNear(
        position,
        RideDiagnosticsConfiguration.headingSampleMeters,
      ),
    );
  }

  /// A spoken prompt actually left the speaker.
  ///
  /// The distance is the point of it (#409): the defect is that a prompt arrives
  /// after the junction, and "after" is a number, not an impression.
  void recordSpokenPrompt({
    required String phrase,
    required double? distanceToManoeuvreMeters,
  }) {
    _add(
      'SPOKEN     "$phrase"  '
      '${distanceToManoeuvreMeters == null ? 'distance to junction unknown' : '${distanceToManoeuvreMeters.round()} m to the junction'}',
    );
  }

  /// Records which renderer actually delivered a phrase. A preference for the
  /// natural pack is not evidence that it beat the safety deadline, so this is
  /// intentionally separate from [recordSpokenPrompt].
  void recordSpeechDelivery({
    required String phrase,
    required SpokenGuidanceOutput output,
  }) {
    final renderer = switch (output) {
      SpokenGuidanceOutput.natural => 'natural voice',
      SpokenGuidanceOutput.systemFallback => 'system fallback',
    };
    _add('VOICE      $renderer  "$phrase"');
  }

  /// Records the platform audio boundary separately from voice selection.
  /// This distinguishes a renderer timeout from focus denial/interruption.
  void recordSpeechLifecycle({
    required String phrase,
    required SpokenGuidanceLifecycleEvent event,
  }) {
    final detail = switch (event) {
      SpokenGuidanceLifecycleEvent.focusAcquired => 'focus acquired',
      SpokenGuidanceLifecycleEvent.focusDenied => 'focus denied',
      SpokenGuidanceLifecycleEvent.playbackCompleted => 'playback complete',
      SpokenGuidanceLifecycleEvent.playbackCancelled => 'playback cancelled',
    };
    _add('AUDIO      $detail  "$phrase"');
  }

  /// An enforcement warning armed or cleared (#418).
  void recordEnforcementWarning({
    required String hazardType,
    required double distanceMeters,
    required bool armed,
    required String? clearedBy,
  }) {
    _add(
      'ENFORCE    ${armed ? 'armed' : 'cleared'}  $hazardType  '
      '${distanceMeters.round()} m'
      '${clearedBy == null ? '' : '  (cleared by $clearedBy)'}',
    );
  }

  /// The route was recalculated (#414).
  void recordReroute({required String reason, required bool succeeded}) {
    _add('REROUTE    $reason  ${succeeded ? 'produced a route' : 'failed'}');
  }

  /// Free-text note, for states worth naming that are not one of the above.
  void recordNote(String note) => _add('NOTE       $note');

  /// The direct phone-to-phone link's state, as the relay reports it (#855).
  ///
  /// Called on every status the relay emits, which is far more often than
  /// anything changes (every exchange refreshes the queue count), so only a
  /// *change* is written: the state moving, a new problem being reported, a peer
  /// appearing or a peer going. The first call writes the starting state, which
  /// is also what a recorder switched on mid-ride needs.
  ///
  /// Peers are written as "phone A", "phone B", never as the endpoint ids the
  /// platform hands over, and never by name.
  void observeNearbyStatus(RelayStatus status) {
    if (!_recording) return;
    final peers = status.peerIds;
    // Labelled first, before any text is scrubbed or written, so a platform
    // message that names a peer in the same status that announces it has already
    // had the id replaced.
    for (final id in peers) {
      _peers.labelFor(id);
    }
    final problem = _problemFor(status);
    final joined = [
      for (final id in peers)
        if (!_nearbyPeerIds.contains(id)) id,
    ];
    final left = [
      for (final id in _nearbyPeerIds)
        if (!peers.contains(id)) id,
    ];
    final stateChanged = _nearbyState != status.state;
    final newProblem = problem != null && problem != _nearbyProblem;
    _nearbyState = status.state;
    _nearbyProblem = problem;
    _nearbyPeerIds = {...peers};
    if (stateChanged || newProblem) {
      _add(
        'TRANSPORT  bluetooth ${_stateWord(status.state)}  '
        '${_phones(peers.length)}'
        '${problem == null ? '' : '  $problem'}',
      );
    }
    for (final id in joined) {
      _add(
        'TRANSPORT  bluetooth peer connected  ${_peers.labelFor(id)}  '
        '(${_phones(peers.length)} now)',
      );
    }
    for (final id in left) {
      _add(
        'TRANSPORT  bluetooth peer lost  ${_peers.labelFor(id)}  '
        '(${_phones(peers.length)} now)',
      );
    }
  }

  /// The ride service's phase moved (#855). Which phases are an answer and which
  /// a failure is decided here, once: a sync in progress, and a relay that is
  /// stopped, say nothing about whether the service can be reached.
  void observeInternetRelay(InternetRelayPhase phase) {
    switch (phase) {
      case InternetRelayPhase.synced:
        observeInternetSync(succeeded: true);
      case InternetRelayPhase.retrying ||
          InternetRelayPhase.failed ||
          InternetRelayPhase.unauthorized ||
          InternetRelayPhase.updateRequired ||
          InternetRelayPhase.serverUpgradeRequired ||
          InternetRelayPhase.unconfigured:
        observeInternetSync(succeeded: false, reason: phase.name);
      case InternetRelayPhase.syncing || InternetRelayPhase.stopped:
        break;
    }
  }

  /// The ride service answered or failed (#855).
  ///
  /// Only the *transitions* are written: the first outcome, the first failure of
  /// a run, and the recovery with how long the run lasted. A phone with no signal
  /// would otherwise write one line per retry for the whole ride.
  ///
  /// [reason] is a short, fixed-vocabulary word from the caller (a phase name),
  /// not the server's message, which is free text.
  void observeInternetSync({required bool succeeded, String? reason}) {
    if (!_recording) return;
    final now = _clock();
    if (succeeded) {
      if (_internetSucceeding != true) {
        var recovery = '';
        if (_internetSucceeding == false) {
          final since = _internetFailingSince;
          final lasted = since == null
              ? ''
              : ', ${now.difference(since).inSeconds} s';
          recovery =
              '  (recovered after $_internetFailureStreak failed '
              'attempts$lasted)';
        }
        _add('TRANSPORT  internet sync ok$recovery');
      }
      _internetSucceeding = true;
      _internetFailureStreak = 0;
      _internetFailingSince = null;
      return;
    }
    _internetFailureStreak += 1;
    if (_internetSucceeding != false) {
      _internetFailingSince = now;
      _add(
        'TRANSPORT  internet sync failing  '
        '${_scrub(reason ?? 'no reason reported')}',
      );
    }
    _internetSucceeding = false;
  }

  /// A tally of what each route has delivered, written about once a minute
  /// (#855).
  ///
  /// The caller ticks this as often as it likes; the recorder decides whether a
  /// minute has gone by, in fixed slots so a 15-second tick yields a line every
  /// minute and not every minute-and-a-tick. [summarise] is only called when a
  /// line will be written.
  void recordTransportSummaryIfDue(
    TransportEvidenceSummary Function() summarise,
  ) {
    if (!_recording) return;
    final now = _clock();
    final due = _nextTransportSummaryAt;
    if (due != null && now.isBefore(due)) return;
    const interval = RideDiagnosticsConfiguration.transportSummaryInterval;
    _nextTransportSummaryAt = due == null || now.difference(due) >= interval
        ? now.add(interval)
        : due.add(interval);
    recordTransportSummary(summarise());
  }

  /// Writes a tally now, whatever the schedule says. Used at the end of the ride,
  /// so the log closes with the final numbers rather than a minute-old set.
  ///
  /// Each line carries the running total and, in brackets, the change since the
  /// previous tally, so "when did Bluetooth stop delivering" is a subtraction a
  /// reader can do by eye.
  void recordTransportSummary(TransportEvidenceSummary summary) {
    if (!_recording) return;
    final previous = _lastTransportSummary;
    _lastTransportSummary = summary;
    for (final transport in EvidenceTransport.values) {
      final totals = summary.totalsFor(transport);
      final before = previous?.totalsFor(transport);
      String counted(int value, int? earlier) =>
          earlier == null ? '$value' : '$value (+${value - earlier})';
      final oldest = totals.oldestLastReceivedAge;
      final heard = oldest == null
          ? 'nobody heard yet'
          : 'oldest rider ${formatEvidenceAge(oldest)}';
      _add(
        'TRANSPORT  ${transport.name} summary  '
        'events ${counted(totals.events, before?.events)}  '
        'first ${counted(totals.firstDelivered, before?.firstDelivered)}  '
        'presence ${counted(totals.presenceUpdates, before?.presenceUpdates)}  '
        '$heard',
      );
    }
  }

  /// The end-of-ride answer to "did phone-to-phone sharing work?" (#855), in the
  /// same words the ended-ride screen shows.
  void recordTransportVerdict(String verdict) =>
      _add('TRANSPORT  verdict  ${_scrub(verdict)}');

  String? _problemFor(RelayStatus status) {
    final message = status.message;
    if (message == null || message.trim().isEmpty) return null;
    return _scrub(message);
  }

  static String _stateWord(RelayConnectionState state) => switch (state) {
    RelayConnectionState.stopped => 'stopped',
    RelayConnectionState.starting => 'starting',
    RelayConnectionState.searching => 'searching',
    RelayConnectionState.connected => 'connected',
    RelayConnectionState.backingOff => 'reconnecting',
    RelayConnectionState.unavailable => 'unavailable',
    RelayConnectionState.failed => 'failed',
  };

  static String _phones(int count) => count == 1 ? '1 phone' : '$count phones';

  /// Free text from a platform, with every peer id and rider name it may echo
  /// replaced, collapsed to one line and cut to a bounded length.
  ///
  /// A platform error is not expected to name anyone. This is the guard for the
  /// day one does, because what is written here leaves the phone.
  String _scrub(String raw) {
    var text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    for (final id in _peers.knownIds) {
      if (id.isNotEmpty) text = _replaceWord(text, id, _peers.labelFor(id));
    }
    for (final term in privateTerms?.call() ?? const <String>[]) {
      final name = term.trim();
      if (name.length < 2) continue;
      text = _replaceWord(text, name, 'a rider');
    }
    const limit = 120;
    return text.length <= limit ? text : '${text.substring(0, limit - 1)}…';
  }

  /// Replaces [word] with [replacement] wherever it stands alone, so a rider
  /// called "Ed" cannot turn "needed" into "neea rider".
  static String _replaceWord(String text, String word, String replacement) =>
      text.replaceAll(
        RegExp(
          '(?<![\\p{L}\\p{N}])${RegExp.escape(word)}(?![\\p{L}\\p{N}])',
          caseSensitive: false,
          unicode: true,
        ),
        replacement,
      );

  /// Takes up the entries an earlier recording of this **same ride** left behind,
  /// so a ride screen rebuilt part-way through does not replace the log with a
  /// shorter one.
  ///
  /// The recorder lives and dies with the ride screen, and a stored log is
  /// written whole. So when a rider stepped away from a running ride and came
  /// back, or the phone relaunched mid-ride, the new recorder started empty and
  /// its first write **replaced the file** — and a long group ride, with a café
  /// stop in it, is exactly where that happens.
  ///
  /// [previousLog] is the text [render] produced. Its entries go in front of this
  /// recorder's own, and the join is marked, because a log that restarts without
  /// saying so reads as a ride with a gap.
  void continueFrom(String previousLog) {
    final carried = <String>[];
    var carriedDropped = 0;
    final droppedLine = RegExp(r'^(\d+) earlier entries were dropped');
    final entryStart = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}');
    var inEntries = false;
    for (final line in previousLog.split('\n')) {
      if (entryStart.hasMatch(line)) {
        inEntries = true;
        carried.add(line);
      } else if (inEntries && line.isNotEmpty) {
        // A continuation of the entry above, such as a manoeuvre report.
        carried[carried.length - 1] = '${carried.last}\n$line';
      } else if (!inEntries) {
        final match = droppedLine.firstMatch(line);
        if (match != null) carriedDropped += int.parse(match.group(1)!);
      }
    }
    if (carried.isEmpty && carriedDropped == 0) return;
    final joinStamp = _entries.isEmpty
        ? _stamp()
        : _entries.first.substring(0, _entries.first.indexOf(' '));
    _entries.insertAll(0, [
      ...carried,
      '$joinStamp  NOTE       recording continued — the entries above were '
          'recorded earlier in this ride, before the ride screen was reopened',
    ]);
    _dropped += carriedDropped;
    while (_entries.length > RideDiagnosticsConfiguration.maximumEntries) {
      _entries.removeAt(0);
      _dropped += 1;
    }
    onEntry?.call();
  }

  /// Emits the comparison for any manoeuvre the rider has now ridden past.
  ///
  /// This is the line #412 needs and the reason the recorder holds a position
  /// buffer at all: the app's own heading change against the one the bike made.
  /// A disagreement here says the app reasoned from the wrong bearings; agreement
  /// with a wrong instruction says the bucketing is at fault. Those have different
  /// fixes, which is why guessing between them was refused.
  void _resolvePassedManoeuvres() {
    if (_pending.isEmpty) return;
    final resolved = <String>[];
    for (final pending in _pending.values) {
      final departure = _headingAfter(
        pending.position,
        RideDiagnosticsConfiguration.headingSampleMeters,
      );
      if (departure == null) continue;
      final approach = pending.approachHeading;
      resolved.add(pending.key);
      if (approach == null) {
        _add(
          'RIDDEN     ${pending.shownAs}: no approach heading was sampled, so '
          'nothing can be compared',
        );
        continue;
      }
      final actual = _signedDelta(approach, departure);
      _add(
        'RIDDEN     ${pending.shownAs}\n'
        '           actual approach ${_degrees(approach)}\n'
        '           actual departure ${_degrees(departure)}\n'
        '           actual change   ${_signed(actual)}',
      );
    }
    for (final key in resolved) {
      _pending.remove(key);
    }
  }

  /// Heading from the most recent sample about [meters] short of [position].
  double? _headingNear(GeoPoint position, double meters) {
    _PositionSample? best;
    var bestError = double.infinity;
    for (final sample in _recentPositions) {
      final error =
          (GeoCalculations.distanceMeters(sample.point, position) - meters)
              .abs();
      if (error < bestError &&
          error <= RideDiagnosticsConfiguration.headingSampleToleranceMeters) {
        bestError = error;
        best = sample;
      }
    }
    return best?.headingDegrees;
  }

  /// Heading from a sample [meters] *past* [position], which only exists once the
  /// rider has ridden through the junction.
  ///
  /// "Past" is judged by the sample arriving after the closest approach, not by
  /// distance alone — a rider the same distance away before and after the junction
  /// is otherwise indistinguishable.
  double? _headingAfter(GeoPoint position, double meters) {
    var closestIndex = -1;
    var closest = double.infinity;
    for (var index = 0; index < _recentPositions.length; index += 1) {
      final distance = GeoCalculations.distanceMeters(
        _recentPositions[index].point,
        position,
      );
      if (distance < closest) {
        closest = distance;
        closestIndex = index;
      }
    }
    if (closestIndex < 0) return null;
    for (
      var index = closestIndex + 1;
      index < _recentPositions.length;
      index += 1
    ) {
      final sample = _recentPositions[index];
      final distance = GeoCalculations.distanceMeters(sample.point, position);
      if ((distance - meters).abs() <=
          RideDiagnosticsConfiguration.headingSampleToleranceMeters) {
        return sample.headingDegrees;
      }
    }
    return null;
  }

  /// The whole record, as the text that gets shared.
  String render({String? rideCode, String? appBuild}) {
    final lines = <String>[
      'Tail End Charlie · ride diagnostics',
      if (rideCode != null) 'Ride:  $rideCode',
      if (appBuild != null) 'Build: $appBuild',
      'Written: ${_stamp()}',
      '',
      'Positions in this file are this phone\'s own. No other rider\'s position,',
      'no ride or invite secret, and no emergency-contact detail is recorded.',
      'Other phones appear only as "phone A", "phone B" — a label per',
      'connection, not per handset. No rider or Bluetooth device name is recorded.',
      '',
      if (_dropped > 0) ...[
        '$_dropped earlier entries were dropped to stay inside the '
            '${RideDiagnosticsConfiguration.maximumEntries}-entry bound.',
        '',
      ],
      ..._entries,
    ];
    return lines.join('\n');
  }

  static String _degrees(double? value) =>
      value == null ? '—' : '${value.toStringAsFixed(1)}°';

  static String _metersPerSecond(double? value) => value == null
      ? '—'
      : '${value.toStringAsFixed(1)} m/s (${(value * 2.236936).round()} mph)';

  static String _meters(double? value) =>
      value == null ? '—' : '${value.toStringAsFixed(1)} m';

  static String _coordinate(GeoPoint point) =>
      '${point.latitude.toStringAsFixed(6)}, '
      '${point.longitude.toStringAsFixed(6)}';

  /// Signed and named, because "+130°" alone reads as an angle rather than as a
  /// direction of travel. Matches the wording the #302 sheet already uses.
  static String _signed(double? value) {
    if (value == null) return '—';
    final rounded = value.toStringAsFixed(1);
    if (value == 0) return '0.0° (straight on)';
    return value > 0
        ? '+$rounded° (clockwise, to the right)'
        : '$rounded° (anticlockwise, to the left)';
  }

  /// Positive is clockwise, to the right — the same convention
  /// `navigation_guidance.dart` uses, so the two numbers can be compared without
  /// a sign conversion in the reader's head.
  static double _signedDelta(double before, double after) =>
      ((after - before + 540) % 360) - 180;
}

class _PositionSample {
  _PositionSample({
    required this.point,
    required this.headingDegrees,
    required this.recordedAt,
  });

  final GeoPoint point;
  final double? headingDegrees;
  final DateTime recordedAt;
}

class _PendingManoeuvre {
  _PendingManoeuvre({
    required this.key,
    required this.position,
    required this.shownAs,
    required this.approachHeading,
  });

  final String key;
  final GeoPoint position;
  final String shownAs;
  final double? approachHeading;
}

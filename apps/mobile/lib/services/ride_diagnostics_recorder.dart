import '../domain/geo_point.dart';
import 'geo_calculations.dart';
import 'ride_diagnostics_configuration.dart';

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
class RideDiagnosticsRecorder {
  RideDiagnosticsRecorder({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final List<String> _entries = [];
  final List<_PositionSample> _recentPositions = [];

  /// Manoeuvres seen but not yet passed, keyed by the identity the guidance layer
  /// uses, so a manoeuvre re-derived on every position fix is not logged twice.
  final Map<String, _PendingManoeuvre> _pending = {};

  int _dropped = 0;

  /// Entries recorded, oldest first. Exposed for tests and for the report.
  List<String> get entries => List.unmodifiable(_entries);

  /// How many entries were dropped to stay inside the bound.
  int get droppedEntries => _dropped;

  bool get isEmpty => _entries.isEmpty;

  void _add(String line) {
    _entries.add('${_stamp()}  $line');
    // Drop from the front: the end of a ride is where the rider was when they
    // noticed something, so the newest entries are the ones worth keeping.
    while (_entries.length > RideDiagnosticsConfiguration.maximumEntries) {
      _entries.removeAt(0);
      _dropped += 1;
    }
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
  }) {
    _recentPositions.add(
      _PositionSample(point: point, headingDegrees: headingDegrees),
    );
    // Enough to reach back past a junction at speed, and no more.
    if (_recentPositions.length > 240) _recentPositions.removeAt(0);
    _resolvePassedManoeuvres();
  }

  /// The app has decided this is the manoeuvre the rider is riding towards.
  ///
  /// Everything here is what the app reasoned *from*, not just its conclusion:
  /// #412's two candidate causes are told apart by whether `bearingBefore`
  /// matches the road the rider approached on, and that is only answerable if the
  /// number the app used is written down beside the rider's own track.
  void recordManoeuvre({
    required String key,
    required GeoPoint position,
    required String engineType,
    required String? engineModifier,
    required String shownAs,
    required String instructionText,
    required double? bearingBeforeDegrees,
    required double? bearingAfterDegrees,
    required double? headingChangeDegrees,
    required double straightBandDegrees,
    required int? exitNumber,
    required String? drivingSide,
    required int stepCount,
    required String? roadLabel,
  }) {
    if (_pending.containsKey(key)) return;
    _add(
      'MANOEUVRE  $instructionText\n'
      '           shown as        $shownAs\n'
      '           engine          $engineType'
      '${engineModifier == null ? '' : ' / $engineModifier'}\n'
      '           bearing before  ${_degrees(bearingBeforeDegrees)}\n'
      '           bearing after   ${_degrees(bearingAfterDegrees)}\n'
      '           heading change  ${_signed(headingChangeDegrees)}\n'
      '           straight band   ±${straightBandDegrees.toStringAsFixed(0)}°\n'
      '           exit number     ${exitNumber ?? '—'}\n'
      '           driving side    ${drivingSide ?? '—'}\n'
      '           steps merged    $stepCount\n'
      '           road            ${roadLabel ?? '—'}\n'
      '           at              ${_coordinate(position)}',
    );
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
  _PositionSample({required this.point, required this.headingDegrees});

  final GeoPoint point;
  final double? headingDegrees;
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

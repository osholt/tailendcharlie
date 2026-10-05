import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/services/ride_diagnostics_configuration.dart';
import 'package:ride_relay/services/ride_diagnostics_recorder.dart';

/// #855: a group ride's log survives the ride screen being rebuilt.
///
/// The recorder lives and dies with the ride screen, and the stored log is
/// written whole. So a rider who stepped away from a running ride and came back
/// (the café stop), or a phone that relaunched mid-ride, got a **new, empty
/// recorder whose first write replaced the file** — leaving a log of only the
/// last stretch of a ride that was recorded from the start.
void main() {
  late DateTime now;

  RideDiagnosticsRecorder recorderAt(
    DateTime start, {
    void Function()? onEntry,
  }) {
    now = start;
    return RideDiagnosticsRecorder(clock: () => now, onEntry: onEntry);
  }

  test('a rebuilt ride screen keeps what was recorded before it', () {
    final first = recorderAt(DateTime.utc(2026, 10, 4, 10));
    first.recordNote('recording started');
    now = now.add(const Duration(minutes: 30));
    first.recordNote('reached the café');
    final stored = first.render(rideCode: '123456');

    final second = recorderAt(DateTime.utc(2026, 10, 4, 12));
    second.recordNote('recording started');
    second.continueFrom(stored);
    now = now.add(const Duration(minutes: 5));
    second.recordNote('left the café');

    final text = second.render(rideCode: '123456');
    expect(text, contains('reached the café'));
    expect(text, contains('left the café'));
    // In time order: the old entries, then the join, then the new ones.
    expect(
      text.indexOf('reached the café'),
      lessThan(text.indexOf('recording continued')),
    );
    expect(
      text.indexOf('recording continued'),
      lessThan(text.indexOf('left the café')),
    );
  });

  test('the join is marked, so the log does not read as a ride with a gap', () {
    final first = recorderAt(DateTime.utc(2026, 10, 4, 10));
    first.recordNote('earlier');
    final second = recorderAt(DateTime.utc(2026, 10, 4, 12));
    second.recordNote('recording started');

    second.continueFrom(first.render());

    expect(
      second.entries.where((entry) => entry.contains('recording continued')),
      hasLength(1),
    );
    expect(second.render(), contains('before the ride screen was reopened'));
  });

  test('the join note is stamped at the new recording, keeping time order', () {
    final first = recorderAt(DateTime.utc(2026, 10, 4, 10));
    first.recordNote('earlier');
    final second = recorderAt(DateTime.utc(2026, 10, 4, 12));
    second.recordNote('recording started');

    second.continueFrom(first.render());

    final stamps = [
      for (final entry in second.entries)
        entry.substring(0, entry.indexOf(' ')),
    ];
    expect([...stamps]..sort(), stamps, reason: 'entries stay in time order');
  });

  test('a multi-line manoeuvre report comes through whole', () {
    final first = recorderAt(DateTime.utc(2026, 10, 4, 10));
    first.recordManoeuvre(
      key: 'm1',
      position: const GeoPoint(latitude: 10, longitude: 10),
      shownAs: 'right',
      diagnostics: 'Instruction: Turn right\nShown as: right (turn)\nRoad: A38',
    );
    final second = recorderAt(DateTime.utc(2026, 10, 4, 12));

    second.continueFrom(first.render());

    final carried = second.entries.first;
    expect(carried, contains('MANOEUVRE'));
    expect(carried, contains('Instruction: Turn right'));
    expect(carried, contains('Road: A38'));
    // One entry, not four: the continuation lines belong to it.
    expect(
      second.entries.where((entry) => entry.contains('MANOEUVRE')),
      hasLength(1),
    );
  });

  test('the header of the earlier log is not carried as entries', () {
    final first = recorderAt(DateTime.utc(2026, 10, 4, 10));
    first.recordNote('earlier');
    final second = recorderAt(DateTime.utc(2026, 10, 4, 12));

    second.continueFrom(
      first.render(rideCode: '123456', appBuild: '1.0.1+102'),
    );

    final text = second.render(rideCode: '123456');
    // One header, the new one.
    expect(
      'Tail End Charlie · ride diagnostics'.allMatches(text),
      hasLength(1),
    );
    expect('Build:'.allMatches(text), isEmpty);
    expect('Ride:  123456'.allMatches(text), hasLength(1));
  });

  test('the count of entries the earlier log had dropped is kept', () {
    final first = recorderAt(DateTime.utc(2026, 10, 4, 10));
    final overflow = RideDiagnosticsConfiguration.maximumEntries + 40;
    for (var index = 0; index < overflow; index += 1) {
      first.recordNote('entry $index');
    }
    expect(first.droppedEntries, 40);
    final second = recorderAt(DateTime.utc(2026, 10, 4, 12));

    second.continueFrom(first.render());

    // 40 were gone before, and the carried entries plus the join note now sit
    // one over the bound, so one more goes. The total is stated, not forgotten.
    expect(second.droppedEntries, greaterThanOrEqualTo(40));
    expect(second.render(), contains('earlier entries were dropped'));
    expect(
      second.entries.length,
      lessThanOrEqualTo(RideDiagnosticsConfiguration.maximumEntries),
    );
  });

  test('the bound still holds when the earlier log was already full', () {
    final first = recorderAt(DateTime.utc(2026, 10, 4, 10));
    for (
      var index = 0;
      index < RideDiagnosticsConfiguration.maximumEntries;
      index += 1
    ) {
      first.recordNote('old $index');
    }
    final second = recorderAt(DateTime.utc(2026, 10, 4, 12));
    for (var index = 0; index < 10; index += 1) {
      second.recordNote('new $index');
    }

    second.continueFrom(first.render());

    expect(second.entries.length, RideDiagnosticsConfiguration.maximumEntries);
    expect(second.entries.last, contains('new 9'), reason: 'newest is kept');
    expect(second.droppedEntries, greaterThan(0));
  });

  test('text that is not a log changes nothing', () {
    final second = recorderAt(DateTime.utc(2026, 10, 4, 12));
    second.recordNote('recording started');
    final before = second.entries;

    second.continueFrom('');
    second.continueFrom('not a diagnostics log at all\nnothing to carry');

    expect(second.entries, before);
  });

  test('the stored log is rewritten once the entries are carried in', () {
    var written = 0;
    final first = recorderAt(DateTime.utc(2026, 10, 4, 10));
    first.recordNote('earlier');
    final second = recorderAt(
      DateTime.utc(2026, 10, 4, 12),
      onEntry: () => written += 1,
    );

    second.continueFrom(first.render());

    expect(written, 1);
  });

  test('a log can be continued more than once', () {
    final first = recorderAt(DateTime.utc(2026, 10, 4, 10));
    first.recordNote('stretch one');
    final second = recorderAt(DateTime.utc(2026, 10, 4, 11));
    second.continueFrom(first.render());
    second.recordNote('stretch two');
    final third = recorderAt(DateTime.utc(2026, 10, 4, 12));
    third.continueFrom(second.render());
    third.recordNote('stretch three');

    final text = third.render();
    expect(text, contains('stretch one'));
    expect(text, contains('stretch two'));
    expect(text, contains('stretch three'));
    expect('recording continued'.allMatches(text), hasLength(2));
  });
}

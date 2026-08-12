import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every share that hands over a ride must hand over its recorded log too (#456).
///
/// The fault this guards was not a broken feature — the recorder worked, and the
/// share it was wired into worked. It was that **one of several doors to the same
/// room was left unwired**: `EndedRideScreen` called the sharer with no
/// `diagnostics:` argument, and that is the door a rider uses once the ride is
/// over. The evidence from a whole ride was dropped without a word.
///
/// This is #439 twice over now — the Settings switch reachable from one of two
/// call sites, then the log attachable from one of several. So the check is
/// structural rather than behavioural: any file that calls the summary sharer must
/// pass the log, and a new share door added later fails this test until it does.
///
/// Read as source because driving these screens needs a whole app, a session and a
/// relay, while what actually broke was an argument list.
void main() {
  test('every caller of the summary sharer passes the recorded log', () {
    final offenders = <String>[];

    for (final path in _dartFilesUnder('lib')) {
      final source = File(path).readAsStringSync();
      // The *summary* sharer specifically. Other shares in the app hand over a
      // route or a recap image, which carry no diagnostics and should not.
      if (!source.contains('RideSummarySharer')) continue;
      if (!source.contains('.share(')) continue;
      // The sharer's own definition states the parameter rather than passing it.
      if (path.endsWith('services/ride_summary_exporter.dart')) continue;
      if (!source.contains('diagnostics:')) offenders.add(path);
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'these call the ride summary sharer without attaching the recorded '
          'diagnostics log, so a rider recording a ride would lose it there',
    );
  });

  test('the ended-ride screen is one of those callers', () {
    // Guards the test above against passing because it found nothing: if this
    // screen stops calling the sharer, the check has lost its subject.
    final source = File(
      'lib/features/ride/ended_ride_screen.dart',
    ).readAsStringSync();

    expect(source, contains('.share('));
    expect(source, contains('diagnostics:'));
  });

  test('the log can be reached from Settings, not only from a ride', () {
    // The door that does not depend on being anywhere in particular. A rider who
    // has finished the ride and moved on had no way at all before this.
    final source = File(
      'lib/features/settings/ride_diagnostics_section.dart',
    ).readAsStringSync();

    expect(source, contains('logStore'));
    expect(source, contains('SharePlus'));
  });
}

Iterable<String> _dartFilesUnder(String directory) => Directory(directory)
    .listSync(recursive: true)
    .whereType<File>()
    .map((file) => file.path)
    .where((path) => path.endsWith('.dart'));

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/data/ride_diagnostics_log_store.dart';

void main() {
  late Directory directory;
  late FileRideDiagnosticsLogStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('diagnostics-log-store');
    store = FileRideDiagnosticsLogStore(
      Directory('${directory.path}/ride_diagnostics'),
    );
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  group('a recorded ride can be read back after it has finished (#456)', () {
    test('nothing is stored before a ride is recorded', () async {
      expect(await store.list(), isEmpty);
      expect(await store.latest(), isNull);
      expect(await store.read('ride-1'), isNull);
    });

    test('a written log survives and reads back whole', () async {
      await store.write(rideId: 'ride-1', text: _log('ABCD'));

      expect(await store.read('ride-1'), _log('ABCD'));
    });

    test('writing again replaces rather than accumulates', () async {
      await store.write(rideId: 'ride-1', text: _log('ABCD'));
      await store.write(rideId: 'ride-1', text: '${_log('ABCD')}\nlater entry');

      expect(await store.read('ride-1'), contains('later entry'));
      expect(await store.list(), hasLength(1));
    });

    test('the ride code is read back out of the log itself', () async {
      await store.write(rideId: 'ride-1', text: _log('ABCD'));

      final log = await store.latest();

      // Read rather than stored alongside, so there is no second copy to fall out
      // of step with the file a rider actually holds.
      expect(log?.rideCode, 'ABCD');
      expect(log?.fileName, 'tail-end-charlie-diagnostics-ABCD.txt');
    });

    test('a log with no ride code is still offered', () async {
      await store.write(
        rideId: 'ride-1',
        text: 'Tail End Charlie · ride diagnostics',
      );

      final log = await store.latest();

      expect(log, isNotNull);
      expect(log!.rideCode, isNull);
      expect(log.fileName, contains('ride-1'));
    });
  });

  group('the store does not grow without bound', () {
    test('only the newest few rides are kept, and the oldest go', () async {
      final kept = FileRideDiagnosticsLogStore.maximumRetainedLogs;

      for (var index = 0; index < kept + 3; index += 1) {
        await store.write(
          rideId: 'ride-$index',
          // Minutes apart, as real rides are. Written a second apart, the file
          // timestamps would tie and pruning kept the right *number* while
          // dropping the wrong ones.
          text: _log('CODE$index', at: DateTime.utc(2026, 8, 12, 9, index)),
        );
      }

      final logs = await store.list();

      expect(logs, hasLength(kept));
      expect(logs.first.rideCode, 'CODE${kept + 2}', reason: 'newest first');
      expect(
        logs.map((log) => log.rideId),
        isNot(contains('ride-0')),
        reason: 'the oldest is the one to drop',
      );
      expect(
        logs.map((log) => log.rideId),
        contains('ride-${kept + 2}'),
        reason: 'the newest must never be the one pruned',
      );
    });

    test('logs written inside the same second still order correctly', () async {
      // The case that exposed the file-timestamp ordering: `lastModified` has
      // one-second resolution, so these two are indistinguishable by it.
      await store.write(
        rideId: 'earlier',
        text: _log('AAAA', at: DateTime.utc(2026, 8, 12, 9, 0, 1)),
      );
      await store.write(
        rideId: 'later',
        text: _log('BBBB', at: DateTime.utc(2026, 8, 12, 9, 0, 2)),
      );

      expect((await store.list()).map((log) => log.rideId), [
        'later',
        'earlier',
      ]);
    });

    test('the written-at is read from the header, not the file', () {
      // Asserted directly as well as through ordering: two logs written in the
      // same real second can order correctly by luck, so the ordering test alone
      // does not reliably catch a regression to the filesystem clock.
      expect(
        RideDiagnosticsLog.writtenAtIn(
          _log('ABCD', at: DateTime.utc(2026, 8, 12, 9, 41, 30)),
        ),
        DateTime.utc(2026, 8, 12, 9, 41, 30),
      );
      expect(RideDiagnosticsLog.writtenAtIn('no header here'), isNull);
    });

    test('a header value further down the log is not read as the header', () {
      // A recorded entry can contain the word, and a log is thousands of lines.
      final log = '${_log('ABCD')}\n${'filler\n' * 20}Ride:  WRONG';

      expect(RideDiagnosticsLog.rideCodeIn(log), 'ABCD');
    });

    test('a log with no written-at falls back to the file time', () async {
      await store.write(rideId: 'ride-1', text: 'Ride:  ABCD');

      final log = await store.latest();

      expect(log, isNotNull);
      expect(log!.writtenAt.year, greaterThan(2000));
    });
  });

  // #855: on 4 October the operator could only share Where To logs after a group
  // ride. Every Where To navigation writes a log, and they all shared one pool of
  // five with the rides.
  group('Where To navigations cannot push a ride\'s log out', () {
    const personal = RideDiagnosticsLog.personalNavigationRideCode;

    test('a ride\'s log survives any number of newer Where To logs', () async {
      await store.write(
        rideId: 'group-ride',
        text: _log('123456', at: DateTime.utc(2026, 10, 4, 10)),
      );

      // A day of planning and replanning legs: far more than the pool of five.
      for (var index = 0; index < 12; index += 1) {
        await store.write(
          rideId: 'where-to-$index',
          text: _log(personal, at: DateTime.utc(2026, 10, 4, 12, index)),
        );
      }

      final logs = await store.list();
      expect(
        logs.map((log) => log.rideId),
        contains('group-ride'),
        reason: 'a short navigation must never evict the group ride',
      );
    });

    test('Where To logs are bounded on their own, newest kept', () async {
      final kept = FileRideDiagnosticsLogStore.maximumRetainedPersonalLogs;

      for (var index = 0; index < kept + 4; index += 1) {
        await store.write(
          rideId: 'where-to-$index',
          text: _log(personal, at: DateTime.utc(2026, 10, 4, 12, index)),
        );
      }

      final navigations = (await store.list()).where(
        (log) => log.isPersonalNavigation,
      );
      expect(navigations, hasLength(kept));
      expect(
        navigations.map((log) => log.rideId),
        contains('where-to-${kept + 3}'),
        reason: 'the newest is never the one dropped',
      );
      expect(
        navigations.map((log) => log.rideId),
        isNot(contains('where-to-0')),
      );
    });

    test(
      'rides are still bounded, and Where To logs do not count against them',
      () async {
        final kept = FileRideDiagnosticsLogStore.maximumRetainedLogs;
        for (var index = 0; index < kept + 2; index += 1) {
          await store.write(
            rideId: 'ride-$index',
            text: _log('CODE$index', at: DateTime.utc(2026, 10, 3, 9, index)),
          );
        }
        for (var index = 0; index < 3; index += 1) {
          await store.write(
            rideId: 'where-to-$index',
            text: _log(personal, at: DateTime.utc(2026, 10, 4, 12, index)),
          );
        }

        final logs = await store.list();
        final rides = logs.where((log) => !log.isPersonalNavigation);
        expect(rides, hasLength(kept));
        expect(rides.map((log) => log.rideId), isNot(contains('ride-0')));
        expect(logs.where((log) => log.isPersonalNavigation), hasLength(3));
      },
    );
  });

  group('a log is named for what it is in a list', () {
    test('a Where To navigation says so rather than PERSONAL', () async {
      await store.write(
        rideId: 'where-to',
        text: _log(RideDiagnosticsLog.personalNavigationRideCode),
      );

      final log = (await store.latest())!;

      expect(log.isPersonalNavigation, isTrue);
      expect(log.title, 'Where To navigation');
      // The attachment keeps its name: this is only about the list.
      expect(log.fileName, 'tail-end-charlie-diagnostics-PERSONAL.txt');
    });

    test('a ride is named by its code', () async {
      await store.write(rideId: 'ride-1', text: _log('123456'));

      final log = (await store.latest())!;

      expect(log.isPersonalNavigation, isFalse);
      expect(log.title, 'Ride 123456');
    });
  });

  group('a ride id is not trusted as a file name', () {
    test('a traversal attempt cannot escape the directory', () async {
      // Ride ids arrive in relay payloads, so this is untrusted input reaching a
      // path.
      await store.write(rideId: '../escaped', text: _log('ABCD'));

      expect(await store.read('../escaped'), _log('ABCD'));
      final escaped = File('${directory.path}/escaped.txt');
      expect(await escaped.exists(), isFalse);
      expect(await store.list(), hasLength(1));
    });
  });

  group('a damaged store does not take the rest with it', () {
    test('a non-log file in the directory is ignored', () async {
      await store.write(rideId: 'ride-1', text: _log('ABCD'));
      await File('${store.directory.path}/notes.json').writeAsString('{}');

      expect(await store.list(), hasLength(1));
    });
  });

  group('the in-memory store behaves the same way', () {
    test('write, read, latest', () async {
      final memory = InMemoryRideDiagnosticsLogStore();

      await memory.write(rideId: 'ride-1', text: _log('ABCD'));

      expect(await memory.read('ride-1'), _log('ABCD'));
      expect((await memory.latest())?.rideCode, 'ABCD');
    });
  });
}

/// A log shaped the way [RideDiagnosticsRecorder.render] shapes one, since the
/// store reads the ride code and the written-at back out of that header.
String _log(String rideCode, {DateTime? at}) {
  final written = (at ?? DateTime.utc(2026, 8, 12, 18)).toIso8601String();
  return 'Tail End Charlie · ride diagnostics\n'
      'Ride:  $rideCode\n'
      'Build: 1.0.1+51\n'
      'Written: $written\n'
      '\n'
      '$written  NOTE       recording started';
}

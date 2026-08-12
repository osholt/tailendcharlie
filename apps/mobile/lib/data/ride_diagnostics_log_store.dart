import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Recorded diagnostics logs, kept on disk so a ride can be handed over **after**
/// it has finished (#456).
///
/// ## Why this exists
///
/// The recorder shipped holding its entries in a list owned by the ride screen's
/// state, and the log was attached to one share inside the live ride. So the first
/// rider to record a ride ended it, left the screen, and lost the evidence — the
/// reported symptom being simply *"I wasn't given an option to share it when I
/// ended the ride"*.
///
/// An instrument that only answers while you are still holding it is not an
/// instrument. The point of recording is to explain something afterwards, and
/// afterwards routinely means the next morning, on a phone that has since been
/// through a tunnel, a phone call and a low-memory kill.
///
/// ## Shape
///
/// One file per ride, named by ride id, holding exactly the text that gets
/// shared — the same `render()` output, not a second serialisation. That matters:
/// a file that differs from what the share sheet sends is a second thing to keep
/// in step, and the reader of a log cannot tell which one they are holding.
///
/// Writes are whole-file rather than appended for the same reason. Entries arrive
/// a handful per minute at most — a manoeuvre, a prompt, an alert — so rewriting a
/// few hundred kilobytes is cheap, and it keeps one code path for what a log
/// *is*.
abstract interface class RideDiagnosticsLogStore {
  /// Records [text] as the log for [rideId], replacing any earlier version.
  Future<void> write({required String rideId, required String text});

  /// The log for [rideId], or null if that ride was never recorded.
  Future<String?> read(String rideId);

  /// Every retained log, most recently written first.
  Future<List<RideDiagnosticsLog>> list();

  /// The most recently written log, for the rider who has already left the ride
  /// screen and wants the last one.
  Future<RideDiagnosticsLog?> latest() async => (await list()).firstOrNull;
}

/// A stored log, with enough about it to name in a list.
class RideDiagnosticsLog {
  const RideDiagnosticsLog({
    required this.rideId,
    required this.rideCode,
    required this.writtenAt,
    required this.text,
  });

  final String rideId;

  /// The ride's short code, read back out of the log's own header, or null if the
  /// log was written without one. Read rather than stored alongside so there is
  /// no second copy to fall out of step.
  final String? rideCode;

  final DateTime writtenAt;
  final String text;

  /// What the share sheet calls the attachment.
  String get fileName =>
      'tail-end-charlie-diagnostics-${rideCode ?? rideId}.txt';

  /// Parses the `Ride:` line the recorder's header writes.
  static String? rideCodeIn(String text) => _headerValue(text, 'Ride:');

  /// Parses the `Written:` line the recorder's header writes.
  ///
  /// Taken from the log rather than from the file's modification time, which has
  /// **one-second resolution** on the platforms this runs on: two logs written
  /// inside the same second tie, and a tie makes the sort order arbitrary. That is
  /// invisible on real rides minutes apart and immediately visible in a test, which
  /// is how it was found — the pruning kept the right number of logs and dropped
  /// the wrong ones.
  static DateTime? writtenAtIn(String text) {
    final value = _headerValue(text, 'Written:');
    return value == null ? null : DateTime.tryParse(value);
  }

  static String? _headerValue(String text, String label) {
    // Bounded to the header: a `Ride:` inside a recorded entry is not the ride
    // code, and a whole log can be thousands of lines.
    for (final line in text.split('\n').take(8)) {
      if (!line.startsWith(label)) continue;
      final value = line.substring(label.length).trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }
}

class FileRideDiagnosticsLogStore implements RideDiagnosticsLogStore {
  FileRideDiagnosticsLogStore(this.directory);

  final Directory directory;

  /// How many rides' logs are kept.
  ///
  /// Bounded because these hold a route: keeping them forever would quietly
  /// accumulate a location history the rider never asked for. A handful is enough
  /// to cover "the ride before last, actually" and no more.
  static const maximumRetainedLogs = 5;

  static Future<FileRideDiagnosticsLogStore> openDefault() async {
    final support = await getApplicationSupportDirectory();
    return FileRideDiagnosticsLogStore(
      Directory(path.join(support.path, 'ride_diagnostics')),
    );
  }

  @override
  Future<void> write({required String rideId, required String text}) async {
    await directory.create(recursive: true);
    final file = _fileFor(rideId);
    // Written via a temporary and renamed, so a kill mid-write leaves the
    // previous log rather than a truncated one. Same reason the route stores do
    // it.
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(text, flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
    await _prune();
  }

  @override
  Future<String?> read(String rideId) async {
    final file = _fileFor(rideId);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<List<RideDiagnosticsLog>> list() async {
    if (!await directory.exists()) return const [];
    final logs = <RideDiagnosticsLog>[];
    await for (final entity in directory.list()) {
      if (entity is! File || !entity.path.endsWith('.txt')) continue;
      try {
        final text = await entity.readAsString();
        logs.add(
          RideDiagnosticsLog(
            rideId: path.basenameWithoutExtension(entity.path),
            rideCode: RideDiagnosticsLog.rideCodeIn(text),
            // The log's own header first; the file's timestamp only as a fallback
            // for a log written without one. See [RideDiagnosticsLog.writtenAtIn].
            writtenAt:
                RideDiagnosticsLog.writtenAtIn(text) ??
                await entity.lastModified(),
            text: text,
          ),
        );
      } on FileSystemException {
        // A damaged log must never stop the rest being offered.
        continue;
      }
    }
    logs.sort((first, second) => second.writtenAt.compareTo(first.writtenAt));
    return logs;
  }

  @override
  Future<RideDiagnosticsLog?> latest() async => (await list()).firstOrNull;

  /// Drops the oldest logs past [maximumRetainedLogs].
  Future<void> _prune() async {
    final logs = await list();
    for (final log in logs.skip(maximumRetainedLogs)) {
      final file = _fileFor(log.rideId);
      if (await file.exists()) await file.delete();
    }
  }

  /// A ride id reaches this from a relay payload, so it is not trusted to be a
  /// safe file name: anything outside the set below is replaced rather than
  /// escaping the directory.
  File _fileFor(String rideId) => File(
    path.join(
      directory.path,
      '${rideId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.txt',
    ),
  );
}

/// For tests, and for a build whose storage will not open.
class InMemoryRideDiagnosticsLogStore implements RideDiagnosticsLogStore {
  InMemoryRideDiagnosticsLogStore({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Map<String, RideDiagnosticsLog> _logs = {};

  @override
  Future<void> write({required String rideId, required String text}) async {
    _logs[rideId] = RideDiagnosticsLog(
      rideId: rideId,
      rideCode: RideDiagnosticsLog.rideCodeIn(text),
      writtenAt: RideDiagnosticsLog.writtenAtIn(text) ?? _clock(),
      text: text,
    );
  }

  @override
  Future<String?> read(String rideId) async => _logs[rideId]?.text;

  @override
  Future<List<RideDiagnosticsLog>> list() async =>
      _logs.values.toList(growable: false)
        ..sort((first, second) => second.writtenAt.compareTo(first.writtenAt));

  @override
  Future<RideDiagnosticsLog?> latest() async => (await list()).firstOrNull;
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/place_memory.dart';

/// #937: saved places and history never leave the phone.
///
/// A saved Home is the most sensitive coordinate this app could hold. It is not
/// part of the ride journal (so no other rider and no relay sees it), not in the
/// diagnostics log, not in a ride library backup, not in the test-control
/// snapshot, and the module holding it does not talk to a network. These tests
/// read the source, because the only way for it to leak is for a file to start
/// mentioning it.
void main() {
  final files = [
    for (final entity in Directory('lib').listSync(recursive: true))
      if (entity is File && entity.path.endsWith('.dart')) entity,
  ];

  bool mentions(File file) {
    final source = file.readAsStringSync();
    return source.contains('place_memory') ||
        source.contains('PlaceMemory') ||
        source.contains(PlaceMemory.preferenceKey);
  }

  test('only the search surfaces and the store itself mention it', () {
    const allowed = {
      'lib/services/place_memory.dart',
      'lib/features/map/place_memory_panel.dart',
      'lib/features/map/place_search_sheet.dart',
      'lib/features/map/route_review_screen.dart',
      'lib/features/home/home_destination_search.dart',
    };
    final found = {
      for (final file in files)
        if (mentions(file)) file.path,
    };
    expect(
      found.difference(allowed),
      isEmpty,
      reason:
          'saved places and history may only be read by the search surfaces; '
          'a new file mentioning them is a new place they could leak from',
    );
    expect(found, allowed, reason: 'and each of those really does use it');
  });

  test('the journal, relay, diagnostics, backup and test control never '
      'mention it', () {
    final sensitive = [
      for (final file in files)
        if (file.path.startsWith('lib/relay/') ||
            file.path.startsWith('lib/internet/') ||
            file.path.startsWith('lib/data/') ||
            file.path.startsWith('lib/domain/') ||
            file.path.contains('ride_event') ||
            file.path.contains('ride_diagnostics') ||
            file.path.contains('test_control') ||
            file.path.contains('ride_library_backup') ||
            file.path.contains('completed_ride') ||
            file.path.contains('location_sharing') ||
            file.path.contains('leader_broadcast') ||
            file.path.contains('rider_contact_share') ||
            file.path.contains('carplay') ||
            file.path.contains('android_auto'))
          file,
    ];
    expect(sensitive, isNotEmpty, reason: 'the scan found the modules');
    expect(
      sensitive.where(mentions).map((file) => file.path),
      isEmpty,
      reason: 'saved places and history must never be sent or logged',
    );
  });

  test('the store imports nothing that could send it anywhere', () {
    final imports = RegExp(r'''^import\s+['"]([^'"]+)['"]''', multiLine: true)
        .allMatches(File('lib/services/place_memory.dart').readAsStringSync())
        .map((match) => match.group(1)!);
    expect(imports, isNotEmpty);
    for (final import in imports) {
      expect(
        import,
        isNot(anyOf(contains('http'), contains('dart:io'), contains('relay'))),
        reason: import,
      );
      expect(import, isNot(contains('internet/')), reason: import);
    }
    expect(
      imports.toSet(),
      containsAll(<String>[
        'package:shared_preferences/shared_preferences.dart',
      ]),
      reason: 'it lives in the phone\'s own preferences',
    );
  });
}

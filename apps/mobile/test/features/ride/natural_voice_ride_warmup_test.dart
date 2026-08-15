import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The model is ride-shell lifecycle work: the service tests prove what warming
/// does, while this guard proves it is actually requested on every entry path
/// that can make a natural voice active.
void main() {
  final source = File(
    'lib/features/ride/active_ride_shell.dart',
  ).readAsStringSync();

  test('an already-running ride warms its installed natural voice', () {
    expect(
      source,
      contains(
        'if (_observedRideStarted) unawaited(_warmNaturalVoiceIfNeeded())',
      ),
    );
  });

  test('a newly started ride warms before its first safety alert', () {
    expect(
      source,
      contains('if (rideJustStarted) unawaited(_warmNaturalVoiceIfNeeded())'),
    );
  });

  test('enabling the pack or audio during a ride also warms it', () {
    expect(source, contains('addListener(_onSpokenGuidanceChanged)'));
    expect(source, contains('removeListener(_onSpokenGuidanceChanged)'));
  });

  test('silence, no pack, and no active ride stay zero-work paths', () {
    final start = source.indexOf('Future<void> _warmNaturalVoiceIfNeeded()');
    final end = source.indexOf('\n  void _recordSpeechOutput', start);
    final method = source.substring(start, end);

    expect(method, contains('widget.rideController.rideStarted'));
    expect(method, contains('!widget.rideController.rideEnded'));
    expect(method, contains('controller.enabled'));
    expect(method, contains('controller.naturalVoicePack.enabled'));
    expect(method, contains('controller.naturalVoicePack.modelDirectory'));
  });
}

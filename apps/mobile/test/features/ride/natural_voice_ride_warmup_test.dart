import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Speech preparation is ride-shell lifecycle work: the service tests prove
/// what it does, while this guard proves it is requested on every entry path
/// that can make spoken guidance active.
void main() {
  final source = File(
    'lib/features/ride/active_ride_shell.dart',
  ).readAsStringSync();

  test('an already-running ride prepares its selected voice', () {
    expect(
      source,
      contains(
        'if (_observedRideStarted) unawaited(_prepareSpokenGuidanceIfNeeded())',
      ),
    );
  });

  test(
    'a newly started ride prepares speech before its first safety alert',
    () {
      expect(
        source,
        contains(
          'if (rideJustStarted) unawaited(_prepareSpokenGuidanceIfNeeded())',
        ),
      );
    },
  );

  test('enabling the pack or audio during a ride also warms it', () {
    expect(source, contains('addListener(_onSpokenGuidanceChanged)'));
    expect(source, contains('removeListener(_onSpokenGuidanceChanged)'));
  });

  test('silence and no active ride stay zero-work paths', () {
    final start = source.indexOf(
      'Future<void> _prepareSpokenGuidanceIfNeeded()',
    );
    final end = source.indexOf('\n  void _recordSpeechOutput', start);
    final method = source.substring(start, end);

    expect(method, contains('widget.rideController.rideStarted'));
    expect(method, contains('!widget.rideController.rideEnded'));
    expect(method, contains('controller.enabled'));
    expect(
      method,
      contains('speaker.warmUp(enabled: rideActive && controller.enabled)'),
    );
    expect(method, isNot(contains('controller.naturalVoicePack.enabled')));
  });
}

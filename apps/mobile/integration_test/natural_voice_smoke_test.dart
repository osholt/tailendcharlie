// Downloads and exercises the real optional voice pack on a platform runtime.
//
// Run on an iOS or Android simulator/device with enough free storage:
//
//   flutter test integration_test/natural_voice_smoke_test.dart \
//     -d <device-id>
//
// The pack is deliberately left installed so its receipt and generated WAV
// can be inspected after the run. This is a smoke test, not the physical-device
// latency, thermal, pronunciation or reliability gate tracked by #514.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:ride_relay/services/natural_voice_pack.dart';
import 'package:ride_relay/services/neural_spoken_guidance.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'downloads, verifies, synthesizes and plays a whole prompt',
    (tester) async {
      debugPrint('NATURAL VOICE SMOKE opening pack store');
      final store = await DownloadedNaturalVoicePackStore.openDefault();
      debugPrint('NATURAL VOICE SMOKE clearing previous pack');
      await store.remove();

      final download = Stopwatch()..start();
      double? progress;
      debugPrint('NATURAL VOICE SMOKE downloading pack');
      await store.install(onProgress: (value) => progress = value);
      download.stop();
      debugPrint('NATURAL VOICE SMOKE pack installed');
      expect(progress, 1);
      expect(await store.isInstalled(), isTrue);

      final backend = SherpaOnnxNeuralSpeechBackend(
        modelDirectory: store.modelDirectory,
      );
      final engine = NeuralSpokenGuidanceEngine(
        backend: backend,
        voiceProvider: () => NaturalNavigationVoice.george,
      );
      final prepare = Stopwatch()..start();
      debugPrint('NATURAL VOICE SMOKE loading model');
      await engine.configure();
      prepare.stop();

      final synthesisAndPlayback = Stopwatch()..start();
      debugPrint('NATURAL VOICE SMOKE synthesizing and playing prompt');
      await engine.speak(
        'In 2 miles, at the roundabout, turn right onto Wickwar Road.',
      );
      synthesisAndPlayback.stop();

      final cache = Directory(
        path.join(
          (await getTemporaryDirectory()).path,
          DownloadedNaturalVoicePackStore.cacheDirectoryName,
        ),
      );
      final waveFiles = cache
          .listSync()
          .whereType<File>()
          .where((file) => path.extension(file.path) == '.wav')
          .toList();
      expect(waveFiles, isNotEmpty);
      expect(waveFiles.any((file) => file.lengthSync() > 44), isTrue);
      debugPrint(
        'NATURAL VOICE SMOKE download=${download.elapsedMilliseconds}ms '
        'prepare=${prepare.elapsedMilliseconds}ms '
        'synthesis+playback=${synthesisAndPlayback.elapsedMilliseconds}ms '
        'wav=${waveFiles.last.lengthSync()} bytes',
      );
      await engine.stop();
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

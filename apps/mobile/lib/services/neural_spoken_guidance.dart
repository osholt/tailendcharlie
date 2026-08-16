import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'natural_voice_pack.dart';
import 'spoken_guidance.dart';

/// Starts neural audio or reports why it could not start. Completion never
/// carries an error: once the deadline has chosen a fallback, a late worker
/// failure must not surface as an unhandled asynchronous error.
class NeuralSpeechAttempt {
  NeuralSpeechAttempt(this.started, this.completed);

  final Future<void> started;
  final Future<void> completed;
}

abstract interface class NeuralSpeechStarter {
  Future<void> prepare();

  NeuralSpeechAttempt beginSpeak(String phrase);

  /// Abandons one deadline-losing utterance without unloading the model that a
  /// later prompt can still use.
  Future<void> cancelCurrentAttempt();

  Future<void> stop();
}

abstract interface class NeuralSpeechBackend {
  Future<void> prepare();

  Future<String> generate({
    required String phrase,
    required NaturalNavigationVoice voice,
  });

  Future<void> abort();
}

/// Persistent, background-isolate Sherpa-ONNX backend. Loading a 134 MB model
/// or running inference on Flutter's UI isolate would make map interaction
/// stutter precisely when a rider needs it.
class SherpaOnnxNeuralSpeechBackend implements NeuralSpeechBackend {
  SherpaOnnxNeuralSpeechBackend({required this.modelDirectory});

  static const _cacheLimitBytes = 50 * 1024 * 1024;
  static const _cacheFileLimit = 80;

  final String modelDirectory;
  _SherpaVoiceWorker? _worker;
  Future<_SherpaVoiceWorker>? _preparing;
  Directory? _cacheDirectory;
  int _lifecycle = 0;

  @override
  Future<void> prepare() async {
    if (_worker != null) return;
    final lifecycle = _lifecycle;
    final preparing = _preparing ??= _SherpaVoiceWorker.spawn(modelDirectory);
    try {
      final worker = await preparing;
      if (lifecycle != _lifecycle) {
        await worker.dispose();
        throw const _NeuralSpeechSuperseded();
      }
      _worker = worker;
      _cacheDirectory ??= Directory(
        path.join(
          (await getTemporaryDirectory()).path,
          DownloadedNaturalVoicePackStore.cacheDirectoryName,
        ),
      );
      await _cacheDirectory!.create(recursive: true);
      unawaited(_trimCache(_cacheDirectory!).catchError((Object _) {}));
    } finally {
      if (identical(_preparing, preparing)) _preparing = null;
    }
  }

  @override
  Future<String> generate({
    required String phrase,
    required NaturalNavigationVoice voice,
  }) async {
    await prepare();
    final cache = _cacheDirectory!;
    final key = sha256
        .convert(
          utf8.encode(
            '$phrase\u0000${voice.name}\u0000'
            '${DownloadedNaturalVoicePackStore.packId}\u00001.0',
          ),
        )
        .toString();
    final output = File(path.join(cache.path, '$key.wav'));
    if (output.existsSync() && output.lengthSync() > 44) {
      await output.setLastModified(DateTime.now());
      return output.path;
    }
    await _worker!.generate(
      phrase: phrase,
      speakerId: voice.speakerId,
      outputPath: output.path,
    );
    if (!output.existsSync() || output.lengthSync() <= 44) {
      throw StateError('The neural voice produced no audio.');
    }
    unawaited(_trimCache(cache).catchError((Object _) {}));
    return output.path;
  }

  @override
  Future<void> abort() async {
    _lifecycle += 1;
    final worker = _worker;
    final preparing = _preparing;
    _worker = null;
    _preparing = null;
    await worker?.dispose();
    if (preparing != null) {
      // A model that is still loading cannot be synchronously killed because
      // its isolate handle has not reached this object yet. Dispose it the
      // instant spawning finishes so a deadline fallback cannot leak 134 MB.
      unawaited(
        preparing
            .then((lateWorker) => lateWorker.dispose())
            .catchError((Object _) {}),
      );
    }
  }

  static Future<void> _trimCache(Directory directory) async {
    if (!directory.existsSync()) return;
    final files =
        directory
            .listSync()
            .whereType<File>()
            .where((file) => path.extension(file.path) == '.wav')
            .toList()
          ..sort(
            (first, second) =>
                first.lastModifiedSync().compareTo(second.lastModifiedSync()),
          );
    var bytes = files.fold<int>(0, (total, file) => total + file.lengthSync());
    while (files.isNotEmpty &&
        (files.length > _cacheFileLimit || bytes > _cacheLimitBytes)) {
      final oldest = files.removeAt(0);
      bytes -= oldest.lengthSync();
      await oldest.delete();
    }
  }
}

/// Plays complete neural utterances with navigation-grade audio focus.
class NeuralSpokenGuidanceEngine
    implements SpokenGuidanceEngine, NeuralSpeechStarter {
  NeuralSpokenGuidanceEngine({
    required this.backend,
    required this.voiceProvider,
    AudioPlayer? player,
    this.disposePlayerOnStop = false,
  }) : _player = player ?? AudioPlayer();

  final NeuralSpeechBackend backend;
  final NaturalNavigationVoice Function() voiceProvider;
  final AudioPlayer _player;
  final bool disposePlayerOnStop;
  int _attemptGeneration = 0;

  @override
  Future<void> prepare() async {
    await _configureAudio();
    await backend.prepare();
  }

  @override
  Future<void> configure() => prepare();

  @override
  NeuralSpeechAttempt beginSpeak(String phrase) {
    final started = Completer<void>();
    final completed = Completer<void>();
    final generation = ++_attemptGeneration;
    unawaited(() async {
      try {
        await prepare();
        if (generation != _attemptGeneration) {
          throw const _NeuralSpeechSuperseded();
        }
        final file = await backend.generate(
          phrase: phrase,
          voice: voiceProvider(),
        );
        if (generation != _attemptGeneration) {
          throw const _NeuralSpeechSuperseded();
        }
        await _player.setReleaseMode(ReleaseMode.stop);
        final finished = _player.onPlayerComplete.first;
        await _player.play(DeviceFileSource(file));
        if (!started.isCompleted) started.complete();
        await finished;
      } on Object catch (error, stackTrace) {
        if (!started.isCompleted) started.completeError(error, stackTrace);
      } finally {
        if (!completed.isCompleted) completed.complete();
      }
    }());
    return NeuralSpeechAttempt(started.future, completed.future);
  }

  @override
  Future<void> speak(String phrase) async {
    final attempt = beginSpeak(phrase);
    await attempt.started;
    await attempt.completed;
  }

  @override
  Future<void> cancelCurrentAttempt() async {
    _attemptGeneration += 1;
    await _player.stop();
  }

  @override
  Future<void> stop() async {
    _attemptGeneration += 1;
    if (disposePlayerOnStop) {
      await _player.dispose();
    } else {
      await _player.stop();
    }
    await backend.abort();
  }

  static Future<void> _configureAudio() => AudioPlayer.global.setAudioContext(
    AudioContext(
      android: const AudioContextAndroid(
        contentType: AndroidContentType.speech,
        usageType: AndroidUsageType.assistanceNavigationGuidance,
        audioFocus: AndroidAudioFocus.gainTransientMayDuck,
      ),
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playback,
        options: const {
          AVAudioSessionOptions.mixWithOthers,
          AVAudioSessionOptions.duckOthers,
        },
      ),
    ),
  );
}

/// Gives a warmed neural voice a strict opportunity to start, then preserves
/// the existing OS speech path. A slow model can improve a prompt; it can never
/// delay or silence one.
class FailSafeNeuralSpokenGuidanceEngine
    implements SpokenGuidanceEngine, WarmableSpokenGuidanceEngine {
  FailSafeNeuralSpokenGuidanceEngine({
    required this.neural,
    required this.fallback,
    this.startDeadline = const Duration(milliseconds: 800),
    this.warmedStartDeadline = const Duration(milliseconds: 2500),
    this.onOutput,
  });

  final NeuralSpeechStarter neural;
  final SpokenGuidanceEngine fallback;
  final Duration startDeadline;
  final Duration warmedStartDeadline;
  final SpokenGuidanceOutputObserver? onOutput;
  bool _warmed = false;
  Future<void>? _warming;

  @override
  Future<void> configure() async {
    await fallback.configure();
    // Warming is intentionally not awaited. The first urgent prompt still has
    // an immediately configured OS voice while the model loads in parallel.
    unawaited(neural.prepare().catchError((Object _) {}));
  }

  @override
  Future<void> warmUp() async {
    final pending = _warming ??= neural.prepare();
    try {
      await pending;
      _warmed = true;
    } finally {
      if (identical(_warming, pending)) _warming = null;
    }
  }

  @override
  Future<void> speak(String phrase) async {
    final attempt = neural.beginSpeak(phrase);
    try {
      await attempt.started.timeout(
        _warmed || _warming != null ? warmedStartDeadline : startDeadline,
      );
    } on Object {
      await neural.cancelCurrentAttempt();
      await fallback.speak(phrase);
      _reportOutput(phrase, SpokenGuidanceOutput.systemFallback);
      return;
    }
    _reportOutput(phrase, SpokenGuidanceOutput.natural);
    await attempt.completed;
  }

  void _reportOutput(String phrase, SpokenGuidanceOutput output) {
    try {
      onOutput?.call(phrase, output);
    } on Object {
      // Diagnostics and telemetry must never interfere with a spoken warning.
    }
  }

  @override
  Future<void> stop() async {
    await neural.stop();
    await fallback.stop();
  }
}

/// Keeps the Settings switch live during a ride. The ride shell creates its
/// speaker once, so choosing, disabling, or deleting a pack later must be read
/// at the next utterance rather than requiring the whole ride UI to restart.
class AdaptiveNeuralSpokenGuidanceEngine
    implements SpokenGuidanceEngine, WarmableSpokenGuidanceEngine {
  AdaptiveNeuralSpokenGuidanceEngine({
    required this.enabled,
    required this.neuralFactory,
    required this.fallback,
    this.onOutput,
  });

  final bool Function() enabled;
  final NeuralSpeechStarter Function() neuralFactory;
  final SpokenGuidanceEngine fallback;
  final SpokenGuidanceOutputObserver? onOutput;
  FailSafeNeuralSpokenGuidanceEngine? _active;
  bool _fallbackConfigured = false;

  @override
  Future<void> configure() async {
    await fallback.configure();
    _fallbackConfigured = true;
    if (enabled()) await _ensureNatural();
  }

  @override
  Future<void> speak(String phrase) async {
    if (!enabled()) {
      final previous = _active;
      _active = null;
      await previous?.neural.stop();
      if (!_fallbackConfigured) await configure();
      await fallback.speak(phrase);
      _reportOutput(phrase, SpokenGuidanceOutput.systemFallback);
      return;
    }
    await _ensureNatural();
    await _active!.speak(phrase);
  }

  @override
  Future<void> warmUp() async {
    if (!enabled()) return;
    await _ensureNatural();
    await _active!.warmUp();
  }

  Future<void> _ensureNatural() async {
    if (_active != null) return;
    final active = FailSafeNeuralSpokenGuidanceEngine(
      neural: neuralFactory(),
      fallback: fallback,
      onOutput: onOutput,
    );
    _active = active;
    await active.configure();
    _fallbackConfigured = true;
  }

  void _reportOutput(String phrase, SpokenGuidanceOutput output) {
    try {
      onOutput?.call(phrase, output);
    } on Object {
      // Diagnostics and telemetry must never interfere with a spoken warning.
    }
  }

  @override
  Future<void> stop() async {
    await _active?.neural.stop();
    _active = null;
    await fallback.stop();
  }
}

class _SherpaVoiceWorker {
  _SherpaVoiceWorker(this._isolate, this._commands);

  final Isolate _isolate;
  final SendPort _commands;
  int _nextRequest = 0;
  bool _disposed = false;
  final Set<ReceivePort> _responses = {};

  static Future<_SherpaVoiceWorker> spawn(String modelDirectory) async {
    final ready = ReceivePort();
    final isolate = await Isolate.spawn(_voiceWorkerEntry, (
      ready.sendPort,
      modelDirectory,
    ));
    final first = await ready.first;
    ready.close();
    if (first is _VoiceWorkerFailure) {
      isolate.kill(priority: Isolate.immediate);
      throw StateError(first.message);
    }
    if (first is! SendPort) {
      isolate.kill(priority: Isolate.immediate);
      throw StateError('The neural voice worker did not start.');
    }
    return _SherpaVoiceWorker(isolate, first);
  }

  Future<void> generate({
    required String phrase,
    required int speakerId,
    required String outputPath,
  }) async {
    if (_disposed) throw StateError('The neural voice worker was stopped.');
    final id = _nextRequest++;
    final response = ReceivePort();
    _responses.add(response);
    _commands.send(
      _VoiceGenerate(id, phrase, speakerId, outputPath, response.sendPort),
    );
    late final Object? message;
    try {
      message = await response.first;
    } finally {
      _responses.remove(response);
      response.close();
    }
    if (message is _VoiceWorkerFailure) throw StateError(message.message);
    if (message is! _VoiceGenerateDone) {
      throw StateError('The neural voice worker returned an invalid response.');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _isolate.kill(priority: Isolate.immediate);
    for (final response in _responses.toList(growable: false)) {
      response.close();
    }
    _responses.clear();
  }
}

void _voiceWorkerEntry((SendPort, String) arguments) {
  final (ready, modelDirectory) = arguments;
  sherpa.OfflineTts? tts;
  try {
    sherpa.initBindings();
    final config = sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        kokoro: sherpa.OfflineTtsKokoroModelConfig(
          model: path.join(modelDirectory, 'model.int8.onnx'),
          voices: path.join(modelDirectory, 'voices.bin'),
          tokens: path.join(modelDirectory, 'tokens.txt'),
          dataDir: path.join(modelDirectory, 'espeak-ng-data'),
        ),
        numThreads: 2,
        debug: false,
        provider: 'cpu',
      ),
      maxNumSenetences: 1,
    );
    tts = sherpa.OfflineTts(config);
  } on Object catch (error) {
    ready.send(_VoiceWorkerFailure('$error'));
    return;
  }
  final commands = ReceivePort();
  ready.send(commands.sendPort);
  commands.listen((message) {
    if (message is! _VoiceGenerate) return;
    try {
      final audio = tts!.generateWithConfig(
        text: message.phrase,
        config: sherpa.OfflineTtsGenerationConfig(
          sid: message.speakerId,
          speed: 1,
          silenceScale: 0.2,
        ),
      );
      final written = sherpa.writeWave(
        filename: message.outputPath,
        samples: audio.samples,
        sampleRate: audio.sampleRate,
      );
      if (!written) throw StateError('Could not write generated speech.');
      message.reply.send(_VoiceGenerateDone(message.id));
    } on Object catch (error) {
      message.reply.send(_VoiceWorkerFailure('$error'));
    }
  });
}

class _VoiceGenerate {
  const _VoiceGenerate(
    this.id,
    this.phrase,
    this.speakerId,
    this.outputPath,
    this.reply,
  );

  final int id;
  final String phrase;
  final int speakerId;
  final String outputPath;
  final SendPort reply;
}

class _VoiceGenerateDone {
  const _VoiceGenerateDone(this.id);
  final int id;
}

class _VoiceWorkerFailure {
  const _VoiceWorkerFailure(this.message);
  final String message;
}

class _NeuralSpeechSuperseded implements Exception {
  const _NeuralSpeechSuperseded();
}

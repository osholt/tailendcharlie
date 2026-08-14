import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-owned British voices in the optional offline neural pack.
///
/// These IDs are the documented speaker IDs in Kokoro English v0.19. Keeping
/// the mapping in the app rather than inferring it from filenames makes a pack
/// update an explicit, reviewable compatibility decision.
enum NaturalNavigationVoice {
  emma('Emma', 7, 'British female'),
  isabella('Isabella', 8, 'British female'),
  george('George', 9, 'British male'),
  lewis('Lewis', 10, 'British male');

  const NaturalNavigationVoice(this.displayName, this.speakerId, this.detail);

  final String displayName;
  final int speakerId;
  final String detail;

  String get label => '$displayName · Natural · $detail';
}

enum NaturalVoicePackStatus { notInstalled, downloading, installed, failed }

abstract interface class NaturalVoicePackStore {
  String get modelDirectory;

  Future<bool> isInstalled();

  Future<void> install({required ValueChanged<double?> onProgress});

  Future<void> cancelInstall();

  Future<void> remove();
}

/// Downloads and verifies the pinned Kokoro pack, then extracts it without
/// holding either the 103 MB archive or the 153 MB installed model in memory.
class DownloadedNaturalVoicePackStore implements NaturalVoicePackStore {
  DownloadedNaturalVoicePackStore._(
    this._packsDirectory, {
    http.Client Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? http.Client.new;

  static const packId = 'kokoro-int8-en-v0_19';
  static const cacheDirectoryName = 'natural-voice-cache';
  static const downloadSizeBytes = 103248205;
  static const archiveSha256 =
      'c9f0dd393615805b0bab050c340834d5e684e732aec91c0e860cd30e982c08bd';
  static final downloadUri = Uri.parse(
    'https://github.com/k2-fsa/sherpa-onnx/releases/download/'
    'tts-models/$packId.tar.bz2',
  );

  final Directory _packsDirectory;
  final http.Client Function() _clientFactory;
  http.Client? _activeClient;
  bool _cancelled = false;

  static Future<DownloadedNaturalVoicePackStore> openDefault() async {
    final support = await getApplicationSupportDirectory();
    return DownloadedNaturalVoicePackStore._(
      Directory(path.join(support.path, 'voice-packs')),
    );
  }

  @override
  String get modelDirectory => path.join(_packsDirectory.path, packId);

  String get _modelPath => path.join(modelDirectory, 'model.int8.onnx');
  String get _voicesPath => path.join(modelDirectory, 'voices.bin');
  String get _tokensPath => path.join(modelDirectory, 'tokens.txt');
  String get _espeakPath => path.join(modelDirectory, 'espeak-ng-data');
  String get _receiptPath => path.join(modelDirectory, '.installed.json');

  @override
  Future<bool> isInstalled() async {
    final model = File(_modelPath);
    final voices = File(_voicesPath);
    final tokens = File(_tokensPath);
    return model.existsSync() &&
        model.lengthSync() > 100000000 &&
        voices.existsSync() &&
        voices.lengthSync() > 5000000 &&
        tokens.existsSync() &&
        tokens.lengthSync() > 100 &&
        Directory(_espeakPath).existsSync() &&
        File(_receiptPath).existsSync();
  }

  @override
  Future<void> install({required ValueChanged<double?> onProgress}) async {
    if (await isInstalled()) return;
    await _packsDirectory.create(recursive: true);
    _cancelled = false;
    final archive = File(
      path.join(_packsDirectory.path, '.$packId.part.tar.bz2'),
    );
    final staging = Directory(
      path.join(
        _packsDirectory.path,
        '.$packId-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    final client = _clientFactory();
    _activeClient = client;
    try {
      await _downloadArchive(client, archive, onProgress);
      if (_cancelled) throw const _NaturalVoiceInstallCancelled();
      final digest = await sha256.bind(archive.openRead()).first;
      if (digest.toString() != archiveSha256) {
        throw const FormatException(
          'The downloaded voice pack did not match its expected release hash.',
        );
      }

      await staging.create(recursive: true);
      await Isolate.run(
        () => extractFileToDisk(archive.path, staging.path, bufferSize: 65536),
      );
      if (_cancelled) throw const _NaturalVoiceInstallCancelled();
      final extracted = Directory(path.join(staging.path, packId));
      if (!extracted.existsSync()) {
        throw const FormatException(
          'The voice pack layout was not recognised.',
        );
      }
      final destination = Directory(modelDirectory);
      if (destination.existsSync()) await destination.delete(recursive: true);
      await extracted.rename(destination.path);
      await File(_receiptPath).writeAsString(
        jsonEncode({
          'pack': packId,
          'sha256': archiveSha256,
          'source': downloadUri.toString(),
          'installedAt': DateTime.now().toUtc().toIso8601String(),
        }),
        flush: true,
      );
      if (!await isInstalled()) {
        await destination.delete(recursive: true);
        throw const FormatException('The installed voice pack is incomplete.');
      }
      onProgress(1);
    } on http.ClientException {
      if (_cancelled) throw const _NaturalVoiceInstallCancelled();
      rethrow;
    } on SocketException {
      if (_cancelled) throw const _NaturalVoiceInstallCancelled();
      rethrow;
    } finally {
      client.close();
      if (identical(_activeClient, client)) _activeClient = null;
      if (archive.existsSync()) await archive.delete();
      if (staging.existsSync()) await staging.delete(recursive: true);
    }
  }

  /// GitHub release assets are large enough that a radio handover or a CDN
  /// connection reset is normal rather than exceptional. Preserve verified
  /// bytes and continue with HTTP Range instead of making the rider restart a
  /// 103 MB download from zero.
  Future<void> _downloadArchive(
    http.Client client,
    File archive,
    ValueChanged<double?> onProgress,
  ) async {
    const maxAttempts = 6;
    Object? lastFailure;
    for (var attempt = 0; attempt < maxAttempts; attempt += 1) {
      if (_cancelled) throw const _NaturalVoiceInstallCancelled();
      var received = archive.existsSync() ? archive.lengthSync() : 0;
      if (received > downloadSizeBytes) {
        await archive.delete();
        received = 0;
      }
      final request = http.Request('GET', downloadUri);
      if (received > 0) {
        request.headers[HttpHeaders.rangeHeader] = 'bytes=$received-';
      }
      try {
        final response = await client.send(request);
        if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
            received == downloadSizeBytes) {
          onProgress(1);
          return;
        }
        if (response.statusCode != HttpStatus.ok &&
            response.statusCode != HttpStatus.partialContent) {
          throw HttpException(
            'Voice download returned HTTP ${response.statusCode}.',
            uri: downloadUri,
          );
        }
        // A server may ignore Range and return the complete file. Truncate in
        // that case so two valid responses cannot produce one invalid pack.
        final appending =
            received > 0 && response.statusCode == HttpStatus.partialContent;
        if (!appending) received = 0;
        final output = archive.openWrite(
          mode: appending ? FileMode.append : FileMode.write,
        );
        try {
          await for (final chunk in response.stream) {
            if (_cancelled) throw const _NaturalVoiceInstallCancelled();
            output.add(chunk);
            received += chunk.length;
            onProgress((received / downloadSizeBytes).clamp(0, 1));
          }
        } finally {
          await output.close();
        }
        if (received == downloadSizeBytes) return;
        lastFailure = http.ClientException(
          'Voice download ended at $received of $downloadSizeBytes bytes.',
          downloadUri,
        );
      } on _NaturalVoiceInstallCancelled {
        rethrow;
      } on Object catch (error) {
        if (_cancelled) throw const _NaturalVoiceInstallCancelled();
        lastFailure = error;
      }
      if (attempt + 1 < maxAttempts) {
        await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
      }
    }
    throw lastFailure ??
        http.ClientException(
          'The voice download did not complete.',
          downloadUri,
        );
  }

  @override
  Future<void> cancelInstall() async {
    _cancelled = true;
    _activeClient?.close();
  }

  @override
  Future<void> remove() async {
    await cancelInstall();
    final directory = Directory(modelDirectory);
    if (directory.existsSync()) await directory.delete(recursive: true);
    try {
      final temporary = await getTemporaryDirectory();
      final cache = Directory(path.join(temporary.path, cacheDirectoryName));
      if (cache.existsSync()) await cache.delete(recursive: true);
    } on FileSystemException {
      // The model is the source of truth. A best-effort cache cleanup must not
      // leave Settings claiming that a successfully removed pack is enabled.
    }
  }
}

/// Persisted state and install lifecycle for the cross-platform natural voice.
class NaturalVoicePackController extends ChangeNotifier {
  NaturalVoicePackController._(
    this._store,
    this._preferences,
    this._status,
    this._enabled,
    this._voice,
  );

  static const enabledPreferenceKey = 'natural_navigation_voice_enabled';
  static const voicePreferenceKey = 'natural_navigation_voice';

  final NaturalVoicePackStore _store;
  final SharedPreferences? _preferences;
  NaturalVoicePackStatus _status;
  bool _enabled;
  NaturalNavigationVoice _voice;
  double? _downloadProgress;
  String? _failure;

  static Future<NaturalVoicePackController> load({
    NaturalVoicePackStore? store,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final resolvedStore =
        store ?? await DownloadedNaturalVoicePackStore.openDefault();
    final installed = await resolvedStore.isInstalled();
    return NaturalVoicePackController._(
      resolvedStore,
      preferences,
      installed
          ? NaturalVoicePackStatus.installed
          : NaturalVoicePackStatus.notInstalled,
      installed && (preferences.getBool(enabledPreferenceKey) ?? false),
      _voiceNamed(preferences.getString(voicePreferenceKey)),
    );
  }

  NaturalVoicePackController.inMemory({
    required NaturalVoicePackStore store,
    bool installed = false,
    bool enabled = false,
    NaturalNavigationVoice voice = NaturalNavigationVoice.george,
  }) : this._(
         store,
         null,
         installed
             ? NaturalVoicePackStatus.installed
             : NaturalVoicePackStatus.notInstalled,
         installed && enabled,
         voice,
       );

  NaturalVoicePackStatus get status => _status;
  bool get installed => _status == NaturalVoicePackStatus.installed;
  bool get downloading => _status == NaturalVoicePackStatus.downloading;
  bool get enabled => installed && _enabled;
  NaturalNavigationVoice get voice => _voice;
  double? get downloadProgress => _downloadProgress;
  String? get failure => _failure;
  String? get modelDirectory => installed ? _store.modelDirectory : null;

  Future<void> install() async {
    if (installed || downloading) return;
    _status = NaturalVoicePackStatus.downloading;
    _downloadProgress = 0;
    _failure = null;
    notifyListeners();
    try {
      await _store.install(
        onProgress: (progress) {
          _downloadProgress = progress;
          notifyListeners();
        },
      );
      _status = NaturalVoicePackStatus.installed;
      _enabled = true;
      _downloadProgress = 1;
      await _preferences?.setBool(enabledPreferenceKey, true);
    } on _NaturalVoiceInstallCancelled {
      _status = NaturalVoicePackStatus.notInstalled;
      _downloadProgress = null;
    } on Object catch (error, stackTrace) {
      _status = NaturalVoicePackStatus.failed;
      _failure = _friendlyFailure(error);
      if (error is! FormatException && error is! HttpException) {
        debugPrint('Natural voice installation failed: $error\n$stackTrace');
      }
    }
    notifyListeners();
  }

  Future<void> cancelInstall() async {
    if (!downloading) return;
    await _store.cancelInstall();
  }

  Future<void> setEnabled(bool value) async {
    final next = installed && value;
    if (_enabled == next) return;
    _enabled = next;
    await _preferences?.setBool(enabledPreferenceKey, next);
    notifyListeners();
  }

  Future<void> setVoice(NaturalNavigationVoice voice) async {
    final changed = _voice != voice || !_enabled;
    _voice = voice;
    if (installed) _enabled = true;
    await _preferences?.setString(voicePreferenceKey, voice.name);
    await _preferences?.setBool(enabledPreferenceKey, _enabled);
    if (changed) notifyListeners();
  }

  Future<void> remove() async {
    await _store.remove();
    _enabled = false;
    _status = NaturalVoicePackStatus.notInstalled;
    _downloadProgress = null;
    _failure = null;
    await _preferences?.setBool(enabledPreferenceKey, false);
    notifyListeners();
  }

  static NaturalNavigationVoice _voiceNamed(String? name) {
    for (final voice in NaturalNavigationVoice.values) {
      if (voice.name == name) return voice;
    }
    return NaturalNavigationVoice.george;
  }

  static String _friendlyFailure(Object error) {
    if (error is FormatException) return error.message;
    if (error is HttpException) return error.message;
    return 'The natural voice could not be installed. Check the connection and try again.';
  }
}

class _NaturalVoiceInstallCancelled implements Exception {
  const _NaturalVoiceInstallCancelled();
}

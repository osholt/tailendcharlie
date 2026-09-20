import 'dart:async';

/// A camera-ready callback does not mean tiles loaded. Static captures require
/// successful tile requests and a quiet paint interval; any failure forbids
/// caching so an offline blank map cannot replace a previously useful preview.
class PreviewTileReadiness {
  PreviewTileReadiness({
    required this.onReady,
    this.quiet = const Duration(milliseconds: 800),
  });
  final void Function() onReady;
  final Duration quiet;
  int _pending = 0, _tiles = 0;
  bool _failed = false,
      _cameraReady = false,
      _disposed = false,
      _reported = false;
  Timer? _timer;
  void cameraReady() {
    _cameraReady = true;
    _settle();
  }

  Future<T> track<T>(Future<T> Function() load, {bool tile = true}) async {
    _pending++;
    _timer?.cancel();
    try {
      final result = await load();
      if (tile) _tiles++;
      return result;
    } on Object {
      _failed = true;
      rethrow;
    } finally {
      _pending--;
      _settle();
    }
  }

  void _settle() {
    _timer?.cancel();
    if (_disposed ||
        _reported ||
        _failed ||
        !_cameraReady ||
        _pending != 0 ||
        _tiles == 0) {
      return;
    }
    _timer = Timer(quiet, () {
      if (_disposed || _failed || _pending != 0) return;
      _reported = true;
      onReady();
    });
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}

import 'dart:async';

/// A tile request that was withdrawn before its render started.
class TileRequestCancelled implements Exception {
  const TileRequestCancelled();

  @override
  String toString() => 'TileRequestCancelled';
}

/// A bounded least-recently-used store of rendered tile images.
///
/// Vector tiles on the device are only the raw bytes. Turning one into pixels
/// means decoding, clipping and painting it, which costs tens of milliseconds
/// a tile on a phone. This keeps the finished pixels, so zooming back to a
/// level that was just drawn costs nothing instead of the whole pipeline again.
///
/// Values are never copied: the caller shares one before using it, and the
/// cache calls [release] when it lets go of its own reference.
class RenderedTileCache<T> {
  RenderedTileCache({
    required this.maximumBytes,
    required this.sizeOf,
    required this.release,
  });

  final int maximumBytes;
  final int Function(T value) sizeOf;
  final void Function(T value) release;

  // Insertion order is recency: the first entry is the least recently used.
  final _entries = <String, T>{};
  final _sizes = <String, int>{};
  int _bytes = 0;

  int get bytes => _bytes;
  int get length => _entries.length;
  bool contains(String key) => _entries.containsKey(key);

  /// The stored value, marked most recently used. The cache keeps ownership.
  T? get(String key) {
    final value = _entries.remove(key);
    if (value == null) return null;
    _entries[key] = value;
    return value;
  }

  /// Stores [value] and takes ownership of it. A value larger than the whole
  /// budget is released immediately rather than emptying the cache for it.
  void put(String key, T value) {
    remove(key);
    final size = sizeOf(value);
    if (size > maximumBytes) {
      release(value);
      return;
    }
    _entries[key] = value;
    _sizes[key] = size;
    _bytes += size;
    while (_bytes > maximumBytes && _entries.isNotEmpty) {
      remove(_entries.keys.first);
    }
  }

  void remove(String key) {
    final value = _entries.remove(key);
    if (value == null) return;
    _bytes -= _sizes.remove(key) ?? 0;
    release(value);
  }

  void clear() {
    for (final key in _entries.keys.toList()) {
      remove(key);
    }
  }
}

typedef TileDelay = Timer Function(Duration delay, void Function() callback);

/// Decides when, and in what order, rendered tiles are produced.
///
/// A fast pinch crosses several zoom levels in a fraction of a second. The map
/// asks for a full set of tiles at every level it passes and withdraws each set
/// as it moves on, but a render that has started cannot be taken back, so the
/// levels that were only flown through used to be paid for in full. This class
///
/// * answers from the [cache] without waiting,
/// * holds back a miss until the zoom level has been steady for [settleDelay],
///   so levels that are only passed through never start,
/// * runs at most [concurrency] renders, most urgent first, re-ranked every time
///   a slot frees so the tiles under the rider's eye come before the margin,
/// * keeps a render that finished after its request was withdrawn, since the
///   user is likely to come back to it.
class TileRenderScheduler<T> {
  TileRenderScheduler({
    required this.cache,
    required this.share,
    this.concurrency = 4,
    this.settleDelay = const Duration(milliseconds: 90),
    DateTime Function()? now,
    TileDelay? schedule,
  }) : _now = now ?? DateTime.now,
       _schedule = schedule ?? Timer.new;

  final RenderedTileCache<T> cache;

  /// Returns an independently owned reference to a value the cache holds.
  final T Function(T value) share;
  final int concurrency;
  final Duration settleDelay;
  final DateTime Function() _now;
  final TileDelay _schedule;

  final _pending = <_Job<T>>[];
  int _running = 0;
  int? _zoom;
  static final _longAgo = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _zoomChangedAt = _longAgo;
  Timer? _wake;
  bool _disposed = false;

  int get pendingCount => _pending.length;
  int get runningCount => _running;

  /// [urgency] ranks pending requests (lower is sooner) and is read again each
  /// time a render slot frees, so it can follow a moving camera.
  Future<T> load({
    required String key,
    required int zoom,
    required double Function() urgency,
    required bool Function() cancelled,
    required Future<T> Function() render,
  }) {
    if (_disposed) return Future.error(const TileRequestCancelled());
    if (_zoom != zoom) {
      // The first level a map shows was not flown into, so it has no settling
      // to wait out.
      _zoomChangedAt = _zoom == null ? _longAgo : _now();
      _zoom = zoom;
    }
    final stored = cache.get(key);
    if (stored != null) return Future.value(share(stored));
    final job = _Job<T>(
      key: key,
      readyAt: _zoomChangedAt.add(settleDelay),
      urgency: urgency,
      cancelled: cancelled,
      render: render,
    );
    _pending.add(job);
    _pump();
    return job.completer.future;
  }

  void dispose() {
    _disposed = true;
    _wake?.cancel();
    _wake = null;
    for (final job in _pending) {
      job.completer.completeError(const TileRequestCancelled());
    }
    _pending.clear();
    cache.clear();
  }

  void _pump() {
    _wake?.cancel();
    _wake = null;
    while (!_disposed && _running < concurrency) {
      _pending.removeWhere((job) {
        if (!job.cancelled()) return false;
        job.completer.completeError(const TileRequestCancelled());
        return true;
      });
      if (_pending.isEmpty) return;
      final now = _now();
      _Job<T>? best;
      var bestUrgency = double.infinity;
      DateTime? nextReady;
      for (final job in _pending) {
        if (job.readyAt.isAfter(now)) {
          if (nextReady == null || job.readyAt.isBefore(nextReady)) {
            nextReady = job.readyAt;
          }
          continue;
        }
        final urgency = job.urgency();
        if (best == null || urgency < bestUrgency) {
          best = job;
          bestUrgency = urgency;
        }
      }
      if (best == null) {
        _wake = _schedule(nextReady!.difference(now), _pump);
        return;
      }
      _pending.remove(best);
      _start(best);
    }
  }

  void _start(_Job<T> job) {
    _running++;
    Future<T>.sync(job.render)
        .then(
          (value) {
            // Kept even if the request was withdrawn mid-render: the work is
            // done and the rider is as likely to scroll back as not.
            if (!_disposed) cache.put(job.key, share(value));
            job.completer.complete(value);
          },
          onError: (Object error, StackTrace stack) {
            job.completer.completeError(error, stack);
          },
        )
        .whenComplete(() {
          _running--;
          _pump();
        });
  }
}

class _Job<T> {
  _Job({
    required this.key,
    required this.readyAt,
    required this.urgency,
    required this.cancelled,
    required this.render,
  });

  final String key;
  final DateTime readyAt;
  final double Function() urgency;
  final bool Function() cancelled;
  final Future<T> Function() render;
  final completer = Completer<T>();
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/rendered_tile_scheduler.dart';

class _Tile {
  _Tile(this.id, {this.bytes = 1});
  final int id;
  final int bytes;
  bool released = false;
}

class _Clock {
  DateTime now = DateTime.utc(2026, 10, 10);
  final timers = <(DateTime, void Function(), _FakeTimer)>[];

  Timer schedule(Duration delay, void Function() callback) {
    final timer = _FakeTimer();
    timers.add((now.add(delay), callback, timer));
    return timer;
  }

  /// Moves time on and runs every timer that has come due and was not cancelled.
  void advance(Duration by) {
    now = now.add(by);
    for (final entry in timers.toList()) {
      if (entry.$1.isAfter(now)) continue;
      timers.remove(entry);
      if (!entry.$3.isActive) continue;
      entry.$2();
    }
  }

  int get liveTimers => timers.where((t) => t.$3.isActive).length;
}

class _FakeTimer implements Timer {
  bool cancelled = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('RenderedTileCache', () {
    late List<_Tile> released;
    RenderedTileCache<_Tile> build(int budget) => RenderedTileCache<_Tile>(
      maximumBytes: budget,
      sizeOf: (tile) => tile.bytes,
      release: (tile) {
        tile.released = true;
        released.add(tile);
      },
    );

    setUp(() => released = []);

    test('evicts the least recently used tile when over budget', () {
      final cache = build(2);
      final a = _Tile(1), b = _Tile(2), c = _Tile(3);
      cache
        ..put('a', a)
        ..put('b', b)
        ..put('c', c);
      expect(cache.contains('a'), isFalse);
      expect(cache.contains('b'), isTrue);
      expect(cache.contains('c'), isTrue);
      expect(released, [a]);
      expect(cache.bytes, 2);
    });

    test('reading a tile protects it from the next eviction', () {
      final cache = build(2);
      final b = _Tile(2);
      cache
        ..put('a', _Tile(1))
        ..put('b', b);
      expect(cache.get('a'), isNotNull);
      cache.put('c', _Tile(3));
      expect(cache.contains('a'), isTrue);
      expect(cache.contains('b'), isFalse);
      expect(released, [b]);
    });

    test('replacing a key releases the old tile and recounts the bytes', () {
      final cache = build(10);
      final old = _Tile(1, bytes: 4);
      cache
        ..put('a', old)
        ..put('a', _Tile(2, bytes: 3));
      expect(released, [old]);
      expect(cache.bytes, 3);
      expect(cache.length, 1);
    });

    test('a tile bigger than the whole budget is released, not stored', () {
      final cache = build(5);
      cache.put('small', _Tile(1, bytes: 2));
      final huge = _Tile(2, bytes: 9);
      cache.put('huge', huge);
      expect(cache.contains('huge'), isFalse);
      expect(cache.contains('small'), isTrue);
      expect(huge.released, isTrue);
    });

    test('clear releases everything', () {
      final cache = build(10);
      final a = _Tile(1), b = _Tile(2);
      cache
        ..put('a', a)
        ..put('b', b)
        ..clear();
      expect(cache.length, 0);
      expect(cache.bytes, 0);
      expect(released, containsAll([a, b]));
    });
  });

  group('TileRenderScheduler', () {
    late _Clock clock;
    late int shares;
    late TileRenderScheduler<_Tile> scheduler;

    TileRenderScheduler<_Tile> build({
      int concurrency = 2,
      Duration settle = const Duration(milliseconds: 100),
    }) => TileRenderScheduler<_Tile>(
      cache: RenderedTileCache<_Tile>(
        maximumBytes: 100,
        sizeOf: (tile) => tile.bytes,
        release: (tile) => tile.released = true,
      ),
      share: (tile) {
        shares++;
        return _Tile(tile.id);
      },
      concurrency: concurrency,
      settleDelay: settle,
      now: () => clock.now,
      schedule: clock.schedule,
    );

    setUp(() {
      clock = _Clock();
      shares = 0;
      scheduler = build();
    });

    /// Requests a tile and records when its render starts and what it gets.
    ({Future<_Tile> result, Completer<_Tile> render, List<String> started})
    request(
      String key, {
      int zoom = 15,
      double urgency = 0,
      bool Function()? cancelled,
      List<String>? log,
    }) {
      final render = Completer<_Tile>();
      final started = log ?? <String>[];
      final result = scheduler.load(
        key: key,
        zoom: zoom,
        urgency: () => urgency,
        cancelled: cancelled ?? () => false,
        render: () {
          started.add(key);
          return render.future;
        },
      );
      return (result: result, render: render, started: started);
    }

    test('answers a tile it already holds without rendering again', () async {
      final first = request('15/1/1');
      await _settle();
      expect(first.started, ['15/1/1']);
      first.render.complete(_Tile(7));
      expect((await first.result).id, 7);

      final again = request('15/1/1');
      final tile = await again.result;
      expect(again.started, isEmpty, reason: 'a hit must not render');
      expect(tile.id, 7);
      expect(shares, greaterThanOrEqualTo(2));
    });

    test('hands each caller its own copy, never the one it stores', () async {
      final first = request('15/1/1');
      await _settle();
      final rendered = _Tile(7);
      first.render.complete(rendered);
      await first.result;
      expect(
        scheduler.cache.get('15/1/1'),
        isNot(same(rendered)),
        reason: 'the cache must hold its own reference, not the caller\'s',
      );
      final a = await request('15/1/1').result;
      final b = await request('15/1/1').result;
      expect(identical(a, b), isFalse);
      expect(identical(a, rendered), isFalse);
    });

    test(
      'keeps a tile that finished after its request was withdrawn',
      () async {
        var withdrawn = false;
        final first = request('15/2/2', cancelled: () => withdrawn);
        await _settle();
        withdrawn = true;
        first.render.complete(_Tile(9));
        await first.result;

        final back = request('15/2/2');
        expect((await back.result).id, 9);
        expect(back.started, isEmpty);
      },
    );

    test('runs no more renders at once than its limit', () async {
      final log = <String>[];
      final a = request('a', log: log);
      final b = request('b', log: log);
      final c = request('c', log: log);
      await _settle();
      expect(log, ['a', 'b']);
      expect(scheduler.runningCount, 2);
      expect(scheduler.pendingCount, 1);
      a.render.complete(_Tile(1));
      await _settle();
      expect(log, ['a', 'b', 'c']);
      b.render.complete(_Tile(2));
      c.render.complete(_Tile(3));
    });

    test('starts the most urgent tile first and re-ranks as it goes', () async {
      scheduler = build(concurrency: 1);
      final log = <String>[];
      final urgencies = {'far': 9.0, 'near': 1.0, 'mid': 5.0};
      final blocker = request('blocker', log: log);
      Future<_Tile> pending(String key) => scheduler.load(
        key: key,
        zoom: 15,
        urgency: () => urgencies[key]!,
        cancelled: () => false,
        render: () {
          log.add(key);
          return Future.value(_Tile(1));
        },
      );
      final results = [pending('far'), pending('near'), pending('mid')];
      await _settle();
      expect(log, ['blocker']);
      // The camera moves while the first render runs: 'far' becomes the
      // closest, and must be picked on the strength of the new ranking.
      urgencies['far'] = 0.5;
      blocker.render.complete(_Tile(0));
      await Future.wait(results);
      expect(log, ['blocker', 'far', 'near', 'mid']);
    });

    test('holds a miss at a new zoom level until it has settled', () async {
      final warm = request('15/1/1', zoom: 15);
      await _settle();
      warm.render.complete(_Tile(1));
      await warm.result;

      final log = <String>[];
      final fresh = request('12/1/1', zoom: 12, log: log);
      await _settle();
      expect(log, isEmpty, reason: 'a level only just reached must wait');
      expect(clock.liveTimers, 1);

      clock.advance(const Duration(milliseconds: 99));
      await _settle();
      expect(log, isEmpty);
      clock.advance(const Duration(milliseconds: 1));
      await _settle();
      expect(log, ['12/1/1']);
      fresh.render.complete(_Tile(2));
      await fresh.result;
    });

    test('the first level a map shows is drawn without waiting', () async {
      final first = request('15/1/1', zoom: 15);
      await _settle();
      expect(first.started, ['15/1/1']);
      expect(clock.liveTimers, 0);
      first.render.complete(_Tile(1));
    });

    test(
      'does not delay tiles at a zoom level that is already steady',
      () async {
        final first = request('15/1/1', zoom: 15);
        await _settle();
        expect(first.started, ['15/1/1']);
        first.render.complete(_Tile(1));
        await first.result;
        // A pan at the same level, long after the level was reached.
        clock.advance(const Duration(seconds: 5));
        final pan = request('15/2/1', zoom: 15);
        await _settle();
        expect(pan.started, ['15/2/1']);
        pan.render.complete(_Tile(2));
      },
    );

    test('a level that is only flown through never starts a render', () async {
      final log = <String>[];
      final warm = request('15/1/1', zoom: 15);
      await _settle();
      warm.render.complete(_Tile(1));
      await warm.result;
      var l12 = false, l13 = false;
      final a = request('12/1/1', zoom: 12, log: log, cancelled: () => l12);
      clock.advance(const Duration(milliseconds: 40));
      // The pinch carries on to the next level and the map withdraws the first.
      l12 = true;
      final b = request('13/2/2', zoom: 13, log: log, cancelled: () => l13);
      clock.advance(const Duration(milliseconds: 40));
      l13 = true;
      final c = request('14/4/4', zoom: 14, log: log);
      await expectLater(a.result, throwsA(isA<TileRequestCancelled>()));
      await expectLater(b.result, throwsA(isA<TileRequestCancelled>()));
      clock.advance(const Duration(milliseconds: 100));
      await _settle();
      expect(log, ['14/4/4'], reason: 'only the level it settled at is drawn');
      c.render.complete(_Tile(3));
      await c.result;
    });

    test('a withdrawn request is dropped without rendering', () async {
      final log = <String>[];
      final blocker1 = request('b1', log: log);
      final blocker2 = request('b2', log: log);
      var withdrawn = false;
      final doomed = request('doomed', log: log, cancelled: () => withdrawn);
      final live = request('live', log: log);
      await _settle();
      withdrawn = true;
      blocker1.render.complete(_Tile(1));
      await expectLater(doomed.result, throwsA(isA<TileRequestCancelled>()));
      await _settle();
      expect(log, ['b1', 'b2', 'live']);
      blocker2.render.complete(_Tile(2));
      live.render.complete(_Tile(3));
    });

    test('a failed render reports the error and frees its slot', () async {
      scheduler = build(concurrency: 1);
      final log = <String>[];
      final bad = request('bad', log: log);
      final good = request('good', log: log);
      await _settle();
      bad.render.completeError(StateError('no tile'));
      await expectLater(bad.result, throwsA(isA<StateError>()));
      await _settle();
      expect(log, ['bad', 'good']);
      good.render.complete(_Tile(1));
      expect((await good.result).id, 1);
      expect(scheduler.runningCount, 0);
    });

    test('dispose cancels what is waiting and refuses new requests', () async {
      final kept = request('kept');
      await _settle();
      final stored = _Tile(5);
      kept.render.complete(stored);
      await kept.result;
      expect(scheduler.cache.length, 1);
      final a = request('a');
      final b = request('b');
      final waiting = request('c');
      await _settle();
      scheduler.dispose();
      await expectLater(waiting.result, throwsA(isA<TileRequestCancelled>()));
      await expectLater(
        request('d').result,
        throwsA(isA<TileRequestCancelled>()),
      );
      a.render.complete(_Tile(1));
      b.render.complete(_Tile(2));
      await _settle();
      expect(
        scheduler.cache.length,
        0,
        reason: 'nothing is kept after dispose',
      );
    });

    test('dispose releases the images the cache holds', () async {
      final kept = request('kept');
      await _settle();
      kept.render.complete(_Tile(5));
      await kept.result;
      final held = scheduler.cache.get('kept')! as _Tile;
      expect(held.released, isFalse);
      scheduler.dispose();
      expect(held.released, isTrue, reason: 'a leaked image is leaked memory');
    });
  });
}

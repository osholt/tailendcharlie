// One connectivity answer from several channels (#174).
//
// A tester photographed three cards at once: `Searching nearby · 106 queued`, a
// green "Server sync succeeded", and an amber "Live rider positions are paused
// because the ride service cannot be reached". Every one of them was accurate.
// Together they told a rider nothing, which is the defect.

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/ride_connectivity_summary.dart';

void main() {
  final now = DateTime.utc(2026, 7, 27, 18);

  RideConnectivitySummary summarise({
    bool transportActive = true,
    bool positionsPaused = false,
    int queuedEventCount = 0,
    Duration? syncedAgo = Duration.zero,
  }) => RideConnectivitySummary.from(
    transportActive: transportActive,
    positionsPaused: positionsPaused,
    queuedEventCount: queuedEventCount,
    lastSuccessfulSync: syncedAgo == null ? null : now.subtract(syncedAgo),
    now: now,
  );

  test('the reported field state resolves to one answer, and it is no', () {
    // Exactly what was on screen: the batch had synced, and positions were
    // paused. The old surfaces said both. This has to say one thing.
    final summary = summarise(positionsPaused: true, queuedEventCount: 106);

    expect(summary.state, RideConnectivityState.notReaching);
    expect(summary.headline, 'The group cannot see where you are');
    expect(
      summary.detail,
      contains('resume on their own'),
      reason: 'the rider needs to know whether to do something',
    );
  });

  test('a paused position channel outranks a successful sync', () {
    expect(
      summarise(positionsPaused: true, syncedAgo: Duration.zero).state,
      RideConnectivityState.notReaching,
      reason: 'a synced journal does not mean the group can see you move',
    );
  });

  test('everything current and empty reads as reaching', () {
    final summary = summarise(syncedAgo: const Duration(seconds: 5));

    expect(summary.state, RideConnectivityState.reaching);
    expect(summary.detail, contains('up to date'));
  });

  test('a sync old enough to distrust stops counting as success', () {
    final fresh = summarise(syncedAgo: const Duration(seconds: 89));
    final stale = summarise(syncedAgo: const Duration(seconds: 91));

    expect(fresh.state, RideConnectivityState.reaching);
    expect(stale.state, RideConnectivityState.degraded);
    expect(
      stale.detail,
      contains('a minute ago'),
      reason: 'the old card claimed success with no age at all',
    );
    expect(
      summarise(syncedAgo: const Duration(minutes: 12)).detail,
      contains('12 minutes ago'),
    );
    expect(
      summarise(syncedAgo: const Duration(hours: 3)).detail,
      contains('3 hours ago'),
    );
  });

  test('never having synced is not success', () {
    final summary = summarise(syncedAgo: null);

    expect(summary.state, RideConnectivityState.degraded);
    expect(
      summary.detail,
      contains('Nothing has reached the ride service yet'),
    );
  });

  test('a queue is reported with what will happen to it', () {
    expect(
      summarise(queuedEventCount: 106).detail,
      '106 ride events are waiting to send, and will go on the next exchanges.',
    );
    expect(summarise(queuedEventCount: 1).detail, contains('One ride event'));
    expect(summarise().detail, isNot(contains('waiting to send')));
  });

  test('a bare number never reaches the rider', () {
    // The whole complaint about "106 queued": a count with no meaning.
    for (final queued in [0, 1, 2, 106]) {
      final detail = summarise(queuedEventCount: queued).detail;
      expect(
        detail,
        matches(RegExp(r'[a-z]')),
        reason: 'every state explains itself in words',
      );
      expect(detail.trim(), endsWith('.'));
    }
  });

  test('no transport at all says so rather than reporting a failure', () {
    final summary = summarise(transportActive: false);

    expect(summary.state, RideConnectivityState.inactive);
    expect(summary.headline, 'Not sharing your position');
    expect(summary.detail, contains('No ride service is connected'));
  });

  test('an inactive transport still accounts for a backlog', () {
    expect(
      summarise(transportActive: false, queuedEventCount: 4).detail,
      contains('4 ride events are waiting'),
    );
  });
}

import 'package:meta/meta.dart';

/// How well the group can see this rider, in one answer.
///
/// The ride dashboard carried three independent connectivity cards, each
/// accurate and jointly useless. A tester photographed all three at once:
/// `Searching nearby · 106 queued`, a green **Server sync succeeded**, and an
/// amber **Live rider positions are paused because the ride service cannot be
/// reached** (#174). Both of the last two were true - the event batch had synced
/// and the presence channel was down - and a rider cannot act on a screen that
/// says yes and no about the same thing.
///
/// So the channels keep their own cards, and this decides the one line above
/// them. The question it answers is the only one a rider is really asking: *is
/// the group seeing where I am?*
enum RideConnectivityState {
  /// Positions are flowing and the journal is current.
  reaching,

  /// Working, but with something outstanding worth naming - a queue that has not
  /// drained, or a sync old enough to stop trusting.
  degraded,

  /// The group is not seeing this rider's position.
  notReaching,

  /// No transport is configured or running, so there is nothing to report.
  inactive,
}

@immutable
class RideConnectivitySummary {
  const RideConnectivitySummary({
    required this.state,
    required this.headline,
    required this.detail,
  });

  final RideConnectivityState state;

  /// The answer, in the rider's terms rather than the transport's.
  final String headline;

  /// Why, and what will happen next. Never a bare number.
  final String detail;

  /// A sync older than this stops counting as success.
  ///
  /// 90 seconds, matching `RouteDeviationConfig.coordinatorStaleAfter`, so
  /// "stale" means the same length of time here as it does when the app decides
  /// a rider's position can no longer be trusted.
  static const staleSyncAfter = Duration(seconds: 90);

  /// [positionsPaused] is the presence channel's own verdict, and it wins.
  /// Whatever the event batch managed, a rider whose positions are paused is a
  /// rider the group cannot see moving.
  ///
  /// [queuedEventCount] is the journal backlog waiting to upload. It is reported
  /// with what will happen to it rather than as a number the rider has to
  /// interpret - `106 queued` told the tester nothing about whether that was
  /// normal.
  factory RideConnectivitySummary.from({
    required bool transportActive,
    required bool positionsPaused,
    required int queuedEventCount,
    required DateTime? lastSuccessfulSync,
    required DateTime now,
  }) {
    final queue = _queueSentence(queuedEventCount);
    if (!transportActive) {
      return RideConnectivitySummary(
        state: RideConnectivityState.inactive,
        headline: 'Not sharing your position',
        detail: queuedEventCount == 0
            ? 'No ride service is connected on this phone.'
            : 'No ride service is connected on this phone. $queue',
      );
    }
    if (positionsPaused) {
      return RideConnectivitySummary(
        state: RideConnectivityState.notReaching,
        headline: 'The group cannot see where you are',
        detail: queuedEventCount == 0
            ? 'Live positions are paused. They resume on their own once the '
                  'ride service can be reached.'
            : 'Live positions are paused. They resume on their own once the '
                  'ride service can be reached. $queue',
      );
    }
    final staleSince = lastSuccessfulSync == null
        ? null
        : now.difference(lastSuccessfulSync);
    if (staleSince == null) {
      return RideConnectivitySummary(
        state: RideConnectivityState.degraded,
        headline: 'Reaching the group, but not just now',
        detail: 'Nothing has reached the ride service yet on this ride. $queue',
      );
    }
    if (staleSince >= staleSyncAfter) {
      return RideConnectivitySummary(
        state: RideConnectivityState.degraded,
        headline: 'Reaching the group, but not just now',
        detail:
            'The last exchange with the ride service was '
            '${_ago(staleSince)} ago. $queue',
      );
    }
    if (queuedEventCount > 0) {
      return RideConnectivitySummary(
        state: RideConnectivityState.degraded,
        headline: 'Reaching the group',
        detail: queue,
      );
    }
    return const RideConnectivitySummary(
      state: RideConnectivityState.reaching,
      headline: 'Reaching the group',
      detail: 'Positions and ride events are up to date.',
    );
  }

  /// What the backlog means, not how big it is.
  ///
  /// A backlog is normal on this design - the journal is the record and the relay
  /// drains it - so the wording says it is going rather than implying a fault.
  static String _queueSentence(int queuedEventCount) {
    if (queuedEventCount == 0) return 'Nothing is waiting to send.';
    if (queuedEventCount == 1) {
      return 'One ride event is waiting to send, and will go on the next '
          'exchange.';
    }
    return '$queuedEventCount ride events are waiting to send, and will go on '
        'the next exchanges.';
  }

  static String _ago(Duration elapsed) {
    if (elapsed.inMinutes < 1) return '${elapsed.inSeconds} seconds';
    if (elapsed.inMinutes == 1) return 'a minute';
    if (elapsed.inHours < 1) return '${elapsed.inMinutes} minutes';
    if (elapsed.inHours == 1) return 'an hour';
    return '${elapsed.inHours} hours';
  }
}

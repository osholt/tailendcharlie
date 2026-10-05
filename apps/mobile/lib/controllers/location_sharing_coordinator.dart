import 'dart:async';

import 'package:flutter/widgets.dart';

import '../domain/imported_route.dart' as route_domain;
import '../domain/marker_assistance.dart';
import '../domain/rider_location.dart';
import '../relay/live_presence.dart';
import '../services/route_progress.dart';
import '../services/sharing_dispersal.dart';
import '../services/sharing_reminder_notifier.dart';
import 'location_sharing_guard.dart';
import 'sharing_reminder_presenter.dart';

/// Everything the coordinator needs from the ride around it, and the two things
/// it can do to it.
///
/// Closures rather than the controllers themselves: the coordinator's whole job
/// is to read a handful of facts and press two switches, and tying it to the
/// concrete controllers would make every one of those a test fixture.
@immutable
class LocationSharingHooks {
  const LocationSharingHooks({
    required this.rideRunning,
    required this.isGroupRide,
    required this.reconciledPresence,
    required this.liveRiderIds,
    required this.peersObservable,
    required this.activeRoute,
    required this.activeMarker,
    required this.ridePausedAt,
    required this.watchersActive,
    required this.suspendPublishing,
    required this.resumePublishing,
    required this.stopLocation,
    required this.startLocation,
    this.note,
  });

  /// The ride has started and has not ended. Nothing is judged otherwise.
  final bool Function() rideRunning;

  /// False for a solo ride, which shares with no group.
  final bool Function() isGroupRide;

  /// The one reconciled live model the map draws from.
  final List<LiveRiderPresence> Function() reconciledPresence;

  /// Who is still in the ride, so a rider who has left is not company.
  final Set<String> Function() liveRiderIds;

  /// Whether this phone can see the group at all right now.
  final bool Function() peersObservable;

  final route_domain.ImportedRoute? Function() activeRoute;

  /// This rider's marker session, or null when not marking.
  final MarkerSessionSummary? Function() activeMarker;

  /// When the leader paused the group, or null while the ride is not paused.
  final DateTime? Function() ridePausedAt;

  /// A watcher link is active. It is a separate, explicit share with its own
  /// expiry, and it needs the location stream.
  final bool Function() watchersActive;

  /// Takes this rider's position off every channel and refuses to publish
  /// another.
  final Future<void> Function() suspendPublishing;

  /// Lets positions out again. Called only once the location stream is back.
  final void Function() resumePublishing;

  /// Stops the location stream.
  final Future<void> Function() stopLocation;

  /// Starts the location stream. Returns whether it actually started.
  final Future<bool> Function() startLocation;

  /// A line for the ride's diagnostics log.
  final void Function(String line)? note;
}

/// Ties the sharing guard to a running ride (#859): feeds it fixes and the state
/// of the group, carries out what it decides, and keeps the notification and the
/// rider's own switch in step with it.
///
/// This is the wiring, kept out of the ride shell so it can be tested and so the
/// shell carries one object instead of a dozen fields. The judgement is
/// [assessDispersal], the timing is [LocationSharingGuard]; nothing here decides
/// anything the two of them did not.
class LocationSharingCoordinator extends ChangeNotifier {
  LocationSharingCoordinator({
    required this.hooks,
    required String? rideName,
    SharingReminderNotifier? notifier,
    SharingDispersalPolicy policy = const SharingDispersalPolicy(),
    DateTime Function()? clock,
    this.evaluationInterval = const Duration(seconds: 30),
  }) : _policy = policy,
       // Built from the same policy the guard runs on, so what a rider is told
       // about the countdown is the countdown.
       copy = SharingCopy.forRide(
         rideName: rideName,
         answerWithin: policy.answerWithin,
       ) {
    guard = LocationSharingGuard(
      policy: policy,
      clock: clock,
      onPause: _pause,
      onResume: _resume,
    );
    _reminder = SharingReminderPresenter(
      notifier: notifier ?? const PlatformSharingReminderNotifier(),
      copy: copy,
    );
    guard.addListener(_onGuardChanged);
  }

  final LocationSharingHooks hooks;
  final SharingCopy copy;
  final SharingDispersalPolicy _policy;

  /// How often the guard looks at the ride around this rider. Its five-minute
  /// continuity gap is ten times this, so a late tick is not read as a suspended
  /// app.
  final Duration evaluationInterval;

  late final LocationSharingGuard guard;
  late final SharingReminderPresenter _reminder;
  Timer? _timer;
  bool _appInForeground = true;
  bool _resuming = false;
  bool _disposed = false;

  /// Whether the rider counted as riding when the question was last drawn. The
  /// wording of an open question depends on it, so a change has to be announced.
  bool _ridingWhenShown = false;

  /// Route progress for this rider's own use. Separate from the map's and the
  /// leader's completion tracker: those are fed on rules of their own, and this
  /// one has to be fed by every rider's fixes, whatever their role.
  final _progress = RouteProgressTracker();
  RouteProgressGeometry? _routeProgress;
  DateTime? _routeProgressAt;

  /// How often the route is re-projected. Every ten seconds is plenty to tell on
  /// the route from off it at riding speed, and keeps a long route off the
  /// per-fix path.
  static const routeProgressInterval = Duration(seconds: 10);

  SharingGuardPhase get phase => guard.phase;
  SharingPauseReason? get pauseReason => guard.pauseReason;
  bool get isPaused => guard.isPaused;

  /// True while "resume" is starting the location stream.
  bool get resuming => _resuming;

  /// Whether the rider has moved lately, for wording the question honestly.
  bool get movedRecently => guard.movedRecently;

  /// How long the question says the rider has been away. "At least", so it stays
  /// true however long the question is left up.
  Duration get awayFor => _policy.promptAfter;

  void start() {
    if (_disposed) return;
    _timer ??= Timer.periodic(evaluationInterval, (_) => unawaited(evaluate()));
  }

  /// Takes every device fix. Called whether or not sharing is paused, because
  /// the guard needs to know whether the rider is still moving.
  void observeFix(LocationSample sample) {
    if (_disposed) return;
    guard.observeFix(sample);
    _trackRoute(sample);
  }

  void _trackRoute(LocationSample sample) {
    final route = hooks.activeRoute();
    if (route == null) {
      _routeProgress = null;
      _routeProgressAt = null;
      return;
    }
    final last = _routeProgressAt;
    if (last != null &&
        sample.recordedAt.difference(last) < routeProgressInterval) {
      return;
    }
    _routeProgressAt = sample.recordedAt;
    _routeProgress = _progress.update(
      route,
      route_domain.GeoPoint(
        latitude: sample.position.latitude,
        longitude: sample.position.longitude,
        recordedAt: sample.recordedAt,
      ),
      recordedAt: sample.recordedAt,
      accuracyMeters: sample.accuracyMeters,
    );
  }

  DispersalRoute? _route() {
    final progress = _routeProgress;
    if (hooks.activeRoute() == null || progress == null) return null;
    return DispersalRoute.fromProgress(
      distanceOffRouteMeters: progress.distanceOffRouteMeters,
      progressMeters: progress.progressMeters,
      totalMeters: progress.totalMeters,
      policy: _policy,
    );
  }

  /// One look at the ride around this rider. Driven by the timer; public so a
  /// test, or a caller that knows something has just changed, can ask now.
  Future<void> evaluate() async {
    if (_disposed || !hooks.rideRunning()) return;
    try {
      await guard.evaluate(
        groupRide: hooks.isGroupRide(),
        peers: dispersalPeersFrom(
          hooks.reconciledPresence(),
          liveRiderIds: hooks.liveRiderIds(),
        ),
        peersObservable: hooks.peersObservable(),
        route: _route(),
        marker: dispersalMarkerFrom(hooks.activeMarker()),
        ridePausedAt: hooks.ridePausedAt(),
      );
    } on Object catch (error) {
      // A tick that cannot read the ride is a tick that decides nothing. It must
      // not become an unhandled error on a timer, and it must not stop the next
      // tick from looking.
      hooks.note?.call(
        'location sharing could not look at the ride: ${error.runtimeType}',
      );
      return;
    }
    // Whether the rider is on the road changes what an unanswered question
    // means, and the question is on screen while it is asked.
    if (guard.phase == SharingGuardPhase.prompting &&
        guard.movedRecently != _ridingWhenShown) {
      _ridingWhenShown = guard.movedRecently;
      _notify();
    }
  }

  /// "Keep sharing".
  void keepSharing() => guard.keepSharing();

  /// "Stop sharing", from the question or from wherever else the rider can reach
  /// it.
  Future<void> stopByRider() => guard.stopSharing();

  Future<void> resumeByRider() async {
    if (_disposed || _resuming) return;
    _resuming = true;
    _notify();
    try {
      await guard.resume();
    } finally {
      _resuming = false;
      _notify();
    }
  }

  /// A rider who raises an alert wants to be found, so an alert switches sharing
  /// back on. Not awaited by the caller: the alert itself must not wait on a
  /// location stream.
  void resumeForSafety() {
    if (guard.isPaused) unawaited(resumeByRider());
  }

  /// The app moved between foreground and background. `inactive` is the
  /// transient state - a call, the app switcher, the notification shade - and
  /// says nothing about whether the rider is looking.
  void onLifecycleChanged(AppLifecycleState state) {
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _appInForeground = true;
      case AppLifecycleState.paused ||
          AppLifecycleState.hidden ||
          AppLifecycleState.detached:
        _appInForeground = false;
      case AppLifecycleState.inactive:
        return;
    }
    _syncReminder();
  }

  /// Takes this rider's position off the relay and off Nearby, and stops the
  /// location stream unless something else still needs it.
  ///
  /// The publishers are closed first and for good. Stopping the stream as well
  /// is what makes the platform's own indicator go out, but it is not what makes
  /// the sharing stop.
  Future<void> _pause(SharingPauseReason reason) async {
    await _attempt('suspending publishing', hooks.suspendPublishing);
    // A watcher link is a separate share the rider granted on purpose, with its
    // own expiry, and it needs this same stream. While one is active the stream
    // stays on for it; it is not the group seeing the rider.
    if (!hooks.watchersActive()) {
      await _attempt('stopping location', hooks.stopLocation);
    }
  }

  /// One step of pausing. The pause has already happened - the guard is paused
  /// and every publisher refuses - so a step that fails must not keep the next
  /// one from running or surface as an unhandled error.
  Future<void> _attempt(String step, Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      hooks.note?.call('location sharing: $step failed: ${error.runtimeType}');
    }
  }

  /// Starts the stream again and only then lets positions out. A rider told
  /// "sharing" while nothing is flowing has been misled.
  Future<bool> _resume() async {
    final bool started;
    try {
      started = await hooks.startLocation();
    } on Object catch (error) {
      hooks.note?.call(
        'location sharing: starting location failed: ${error.runtimeType}',
      );
      return false;
    }
    if (!started) return false;
    hooks.resumePublishing();
    return true;
  }

  void _onGuardChanged() {
    if (_disposed) return;
    // In the ride log, so a ride that was asked or stopped can be read back
    // afterwards.
    final reason = guard.pauseReason;
    final state = guard.lastState;
    hooks.note?.call(
      'location sharing ${guard.phase.name}'
      '${reason == null ? '' : ' (${reason.name})'}'
      '${state == null ? '' : ', ${state.name}'}',
    );
    _ridingWhenShown = guard.movedRecently;
    _syncReminder();
    _notify();
  }

  void _syncReminder() {
    unawaited(
      _reminder.sync(
        phase: guard.phase,
        pauseReason: guard.pauseReason,
        appInForeground: _appInForeground,
        riding: guard.movedRecently,
      ),
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    guard.removeListener(_onGuardChanged);
    guard.dispose();
    unawaited(_reminder.dispose());
    super.dispose();
  }
}

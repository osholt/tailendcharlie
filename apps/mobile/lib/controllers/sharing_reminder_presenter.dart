import '../services/sharing_reminder_notifier.dart';
import 'location_sharing_guard.dart';

/// Decides when the notification for the sharing question is on screen (#859).
///
/// The question is always in the app. The notification exists for the rider who
/// is not looking at it, so it is shown only while the app is in the background,
/// taken down the moment the rider is looking at the app or the question has
/// gone, and shown once per question: a rider who opened the app, saw it and
/// left again has not forgotten it, and being buzzed a second time for the same
/// question is how a reminder gets switched off.
///
/// [sync] is idempotent, so the caller can invoke it on every change of the
/// guard and of the app's lifecycle without keeping track of what it has said.
class SharingReminderPresenter {
  SharingReminderPresenter({required this.notifier, required this.copy});

  final SharingReminderNotifier notifier;
  final SharingCopy copy;

  _Shown _shown = _Shown.nothing;
  bool _promptAlreadyShown = false;
  bool _pauseAlreadyShown = false;

  Future<void> sync({
    required SharingGuardPhase phase,
    required SharingPauseReason? pauseReason,
    required bool appInForeground,
    required bool riding,
  }) async {
    final prompting = phase == SharingGuardPhase.prompting;
    // Only a pause the rider did not choose needs telling: they know about the
    // ones they made.
    final pausedUnanswered =
        phase == SharingGuardPhase.paused &&
        pauseReason == SharingPauseReason.unanswered;
    if (!prompting) _promptAlreadyShown = false;
    if (!pausedUnanswered) _pauseAlreadyShown = false;

    if (!appInForeground && prompting && !_promptAlreadyShown) {
      _promptAlreadyShown = true;
      _shown = _Shown.prompt;
      await notifier.show(
        title: copy.promptTitle,
        body: copy.promptNotificationBody(riding: riding),
      );
      return;
    }
    if (!appInForeground && pausedUnanswered && !_pauseAlreadyShown) {
      _pauseAlreadyShown = true;
      _shown = _Shown.paused;
      await notifier.show(
        title: copy.pausedNotificationTitle,
        body: copy.pausedNotificationBody,
      );
      return;
    }

    final stillWanted =
        !appInForeground &&
        switch (_shown) {
          _Shown.prompt => prompting,
          _Shown.paused => pausedUnanswered,
          _Shown.nothing => false,
        };
    if (_shown != _Shown.nothing && !stillWanted) {
      _shown = _Shown.nothing;
      await notifier.clear();
    }
  }

  /// Takes down whatever is showing, for when the ride is over or left.
  Future<void> dispose() async {
    if (_shown == _Shown.nothing) return;
    _shown = _Shown.nothing;
    await notifier.clear();
  }
}

enum _Shown { nothing, prompt, paused }

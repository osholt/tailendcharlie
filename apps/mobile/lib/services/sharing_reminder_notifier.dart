import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Puts a message in front of a rider whose phone is in a pocket (#859).
///
/// The question "are you still riding?" is only worth asking if it reaches the
/// rider, and the rider it is for is rarely looking at the app: they are parked,
/// or at home, with the phone in a pocket. A local notification is the one
/// channel that works while the app is in the background, and the app is still
/// running there because the ride's location stream keeps it alive.
///
/// This is a courtesy, not a dependency. Notification permission belongs to the
/// rider and is asked for elsewhere, and a phone that refuses it simply never
/// shows these. The question is still in the app, and the countdown behind it
/// does not wait for a notification to be read.
abstract interface class SharingReminderNotifier {
  /// Shows one notification, replacing any this app showed before. Resolves to
  /// whether the platform accepted it.
  Future<bool> show({required String title, required String body});

  /// Removes the notification, if it is still there.
  Future<void> clear();
}

/// The native half lives in `AppDelegate.swift` and `SharingReminderChannel.kt`,
/// and does nothing but post and remove one notification. Everything that decides
/// *whether* to post is in Dart.
class PlatformSharingReminderNotifier implements SharingReminderNotifier {
  const PlatformSharingReminderNotifier({
    this.channel = const MethodChannel(channelName),
  });

  static const channelName = 'me.osholt.ride_relay/sharing_reminder';
  static const showMethod = 'show';
  static const clearMethod = 'clear';

  final MethodChannel channel;

  @override
  Future<bool> show({required String title, required String body}) async {
    try {
      return await channel.invokeMethod<bool>(showMethod, {
            'title': title,
            'body': body,
          }) ??
          false;
    } on MissingPluginException {
      // A platform with no native half: tests, the desktop shells.
      return false;
    } on PlatformException catch (error) {
      if (kDebugMode) debugPrint('Sharing reminder not shown: $error');
      return false;
    }
  }

  @override
  Future<void> clear() async {
    try {
      await channel.invokeMethod<void>(clearMethod);
    } on MissingPluginException {
      // Nothing was ever shown.
    } on PlatformException catch (error) {
      if (kDebugMode) debugPrint('Sharing reminder not cleared: $error');
    }
  }
}

/// What the rider is told, in one place so the app and the notification cannot
/// drift apart.
///
/// Every sentence here describes something the app actually does: the question
/// is in the app, the countdown is real, and "Resume sharing" is a button.
@immutable
class SharingCopy {
  const SharingCopy({required this.groupLabel, required this.answerWithin});

  /// What the group is called in the sentence, from the ride's own name.
  factory SharingCopy.forRide({
    required String? rideName,
    required Duration answerWithin,
  }) {
    final name = rideName?.trim();
    return SharingCopy(
      groupLabel: name == null || name.isEmpty ? 'your group' : name,
      answerWithin: answerWithin,
    );
  }

  final String groupLabel;
  final Duration answerWithin;

  String get _countdown => '${answerWithin.inMinutes} minutes';

  String get promptTitle => 'Still riding with $groupLabel?';

  /// What happens if nobody answers, which is different for a rider who is
  /// parked and one who is on the road: the countdown never runs while they move.
  String _consequence({required bool riding}) => riding
      ? 'Sharing will not stop while you are riding. It stops $_countdown '
            'after you stop, unless you answer.'
      : 'Sharing stops in $_countdown unless you answer.';

  /// On the question in the app, which also says how long the rider has been
  /// away, because that is the reason it is being asked. "At least", so the
  /// sentence stays true however long the question is left up.
  String promptBody(Duration awayFor, {required bool riding}) =>
      'Away from the group for at least ${away(awayFor)}. '
      '${_consequence(riding: riding)}';

  /// In the notification. It cannot carry the buttons, so it says where they
  /// are.
  String promptNotificationBody({required bool riding}) =>
      'You have been away from the group for a while. Open Tail End Charlie to '
      'keep sharing. ${_consequence(riding: riding)}';

  /// On the bar that stays up while sharing is paused.
  String pausedTitle({required bool unanswered}) =>
      unanswered ? 'Location sharing is paused' : 'Location sharing is off';

  String pausedBody({required bool unanswered}) => unanswered
      ? 'It stopped because you were away from the group and did not answer. '
            'Your position is no longer being sent to the group.'
      : 'Your position is no longer being sent to the group.';

  /// The Ride tab card and the ride menu say the same thing in two places, so
  /// the words are here and cannot drift.
  String statusTitle({required bool paused}) => paused
      ? 'You are not sharing your location'
      : 'You are sharing your location with the group';

  String statusBody({required bool paused, required bool unanswered}) => paused
      ? pausedBody(unanswered: unanswered)
      : 'You will be asked whether to stop if you are away from the group for '
            'a while.';

  String menuTitle({required bool paused}) => paused
      ? 'Location sharing is off'
      : 'Sharing your location with the group';

  String menuSubtitle({required bool paused}) =>
      paused ? 'Tap to resume sharing' : 'Tap to stop sharing';

  String get pausedNotificationTitle => 'Location sharing stopped';

  String get pausedNotificationBody =>
      'You were away from $groupLabel and did not answer, so Tail End Charlie '
      'stopped sharing your location. Open the app and tap Resume sharing to '
      'start again.';

  /// "30 minutes", "1 hour 5 minutes".
  static String away(Duration duration) {
    final minutes = duration.inMinutes;
    if (minutes < 60) return '$minutes ${minutes == 1 ? 'minute' : 'minutes'}';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    final hourText = '$hours ${hours == 1 ? 'hour' : 'hours'}';
    if (rest == 0) return hourText;
    return '$hourText $rest ${rest == 1 ? 'minute' : 'minutes'}';
  }
}

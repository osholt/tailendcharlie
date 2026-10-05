import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/sharing_reminder_notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(PlatformSharingReminderNotifier.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('PlatformSharingReminderNotifier', () {
    test('asks the native side to show one notification', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });

      final shown = await const PlatformSharingReminderNotifier(
        channel: channel,
      ).show(title: 'Still riding?', body: 'Open the app.');

      expect(shown, isTrue);
      expect(calls.single.method, 'show');
      expect(calls.single.arguments, {
        'title': 'Still riding?',
        'body': 'Open the app.',
      });
    });

    test('asks the native side to take it down again', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });

      await const PlatformSharingReminderNotifier(channel: channel).clear();

      expect(calls.single.method, 'clear');
    });

    test('a refusal from the platform is not shown and not an error', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => false);

      final shown = await const PlatformSharingReminderNotifier(
        channel: channel,
      ).show(title: 't', body: 'b');

      expect(shown, isFalse);
    });

    test('a platform with no native half does nothing quietly', () async {
      // No handler registered: MissingPluginException.
      const notifier = PlatformSharingReminderNotifier(channel: channel);

      expect(await notifier.show(title: 't', body: 'b'), isFalse);
      await notifier.clear();
    });

    test('a platform error is swallowed', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'denied');
      });
      const notifier = PlatformSharingReminderNotifier(channel: channel);

      expect(await notifier.show(title: 't', body: 'b'), isFalse);
      await notifier.clear();
    });

    test('the channel is the one the native code listens on', () {
      expect(
        PlatformSharingReminderNotifier.channelName,
        'me.osholt.ride_relay/sharing_reminder',
      );
      expect(PlatformSharingReminderNotifier.showMethod, 'show');
      expect(PlatformSharingReminderNotifier.clearMethod, 'clear');
    });
  });

  group('SharingCopy', () {
    const fifteen = Duration(minutes: 15);

    test('names the group by the ride, and falls back to "your group"', () {
      expect(
        SharingCopy.forRide(
          rideName: 'Sunday run',
          answerWithin: fifteen,
        ).promptTitle,
        'Still riding with Sunday run?',
      );
      for (final name in [null, '', '   ']) {
        expect(
          SharingCopy.forRide(
            rideName: name,
            answerWithin: fifteen,
          ).promptTitle,
          'Still riding with your group?',
        );
      }
    });

    test('says how long the rider has been away, and what happens next', () {
      final copy = SharingCopy.forRide(rideName: null, answerWithin: fifteen);

      expect(
        copy.promptBody(const Duration(minutes: 30), riding: false),
        'Away from the group for at least 30 minutes. '
        'Sharing stops in 15 minutes unless you answer.',
      );
      expect(
        copy.promptBody(const Duration(minutes: 30), riding: true),
        'Away from the group for at least 30 minutes. '
        'Sharing will not stop while you are riding. '
        'It stops 15 minutes after you stop, unless you answer.',
      );
    });

    test('takes the countdown from the policy rather than repeating it', () {
      final copy = SharingCopy.forRide(
        rideName: null,
        answerWithin: const Duration(minutes: 20),
      );

      expect(
        copy.promptBody(const Duration(minutes: 30), riding: false),
        contains('20 minutes'),
      );
      expect(
        copy.promptNotificationBody(riding: false),
        contains('20 minutes'),
      );
    });

    test(
      'the notification says where the answer is, because it has no buttons',
      () {
        final copy = SharingCopy.forRide(rideName: null, answerWithin: fifteen);

        expect(
          copy.promptNotificationBody(riding: false),
          contains('Open Tail End Charlie'),
        );
        expect(copy.pausedNotificationBody, contains('Resume sharing'));
      },
    );

    test('the paused wording depends on who paused it', () {
      final copy = SharingCopy.forRide(rideName: null, answerWithin: fifteen);

      expect(copy.pausedTitle(unanswered: true), 'Location sharing is paused');
      expect(copy.pausedBody(unanswered: true), contains('did not answer'));
      expect(copy.pausedTitle(unanswered: false), 'Location sharing is off');
      expect(
        copy.pausedBody(unanswered: false),
        isNot(contains('did not answer')),
      );
    });

    test('the card and the menu say the same thing, from the one place', () {
      final copy = SharingCopy.forRide(rideName: null, answerWithin: fifteen);

      expect(
        copy.statusTitle(paused: false),
        'You are sharing your location with the group',
      );
      expect(
        copy.statusTitle(paused: true),
        'You are not sharing your location',
      );
      expect(
        copy.statusBody(paused: false, unanswered: false),
        contains('asked whether to stop'),
      );
      expect(
        copy.statusBody(paused: true, unanswered: true),
        copy.pausedBody(unanswered: true),
      );
      expect(copy.menuTitle(paused: false), contains('Sharing your location'));
      expect(copy.menuSubtitle(paused: false), 'Tap to stop sharing');
      expect(copy.menuTitle(paused: true), 'Location sharing is off');
      expect(copy.menuSubtitle(paused: true), 'Tap to resume sharing');
    });

    test('says what has stopped without claiming more than it did', () {
      final copy = SharingCopy.forRide(rideName: null, answerWithin: fifteen);

      expect(
        copy.pausedBody(unanswered: false),
        'Your position is no longer being sent to the group.',
      );
      expect(
        copy.pausedBody(unanswered: true),
        contains('Your position is no longer being sent to the group.'),
      );
    });

    test('formats how long in plain words', () {
      expect(SharingCopy.away(const Duration(minutes: 1)), '1 minute');
      expect(SharingCopy.away(const Duration(minutes: 45)), '45 minutes');
      expect(SharingCopy.away(const Duration(hours: 1)), '1 hour');
      expect(
        SharingCopy.away(const Duration(hours: 1, minutes: 1)),
        '1 hour 1 minute',
      );
      expect(
        SharingCopy.away(const Duration(hours: 2, minutes: 35)),
        '2 hours 35 minutes',
      );
    });
  });
}

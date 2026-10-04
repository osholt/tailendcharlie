import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/location_sharing_guard.dart';
import 'package:ride_relay/controllers/sharing_reminder_presenter.dart';
import 'package:ride_relay/services/sharing_reminder_notifier.dart';

class _FakeNotifier implements SharingReminderNotifier {
  final shown = <({String title, String body})>[];
  int cleared = 0;

  @override
  Future<bool> show({required String title, required String body}) async {
    shown.add((title: title, body: body));
    return true;
  }

  @override
  Future<void> clear() async => cleared += 1;
}

void main() {
  late _FakeNotifier notifier;
  late SharingReminderPresenter presenter;

  setUp(() {
    notifier = _FakeNotifier();
    presenter = SharingReminderPresenter(
      notifier: notifier,
      copy: SharingCopy.forRide(
        rideName: 'Sunday run',
        answerWithin: const Duration(minutes: 15),
      ),
    );
  });

  Future<void> sync(
    SharingGuardPhase phase, {
    SharingPauseReason? reason,
    bool foreground = false,
    bool riding = false,
  }) => presenter.sync(
    phase: phase,
    pauseReason: reason,
    appInForeground: foreground,
    riding: riding,
  );

  group('the question', () {
    test('is a notification while the app is in the background', () async {
      await sync(SharingGuardPhase.prompting);

      expect(notifier.shown.single.title, 'Still riding with Sunday run?');
      expect(notifier.shown.single.body, contains('Open Tail End Charlie'));
    });

    test(
      'is not a notification while the rider is looking at the app',
      () async {
        await sync(SharingGuardPhase.prompting, foreground: true);

        expect(notifier.shown, isEmpty);
        expect(notifier.cleared, 0);
      },
    );

    test('is shown once, however often the state is announced', () async {
      for (var index = 0; index < 5; index += 1) {
        await sync(SharingGuardPhase.prompting);
      }

      expect(notifier.shown, hasLength(1));
    });

    test('is taken down when the rider opens the app', () async {
      await sync(SharingGuardPhase.prompting);

      await sync(SharingGuardPhase.prompting, foreground: true);

      expect(notifier.cleared, 1);
    });

    test(
      'is not shown again for the same question when the app is left',
      () async {
        await sync(SharingGuardPhase.prompting);
        await sync(SharingGuardPhase.prompting, foreground: true);

        await sync(SharingGuardPhase.prompting);

        expect(notifier.shown, hasLength(1));
      },
    );

    test('is taken down when it is answered or withdrawn', () async {
      await sync(SharingGuardPhase.prompting);

      await sync(SharingGuardPhase.sharing);

      expect(notifier.cleared, 1);
    });

    test('a second question is a second notification', () async {
      await sync(SharingGuardPhase.prompting);
      await sync(SharingGuardPhase.sharing);

      await sync(SharingGuardPhase.prompting);

      expect(notifier.shown, hasLength(2));
    });

    test('says what happens to a rider who is on the road', () async {
      await sync(SharingGuardPhase.prompting, riding: true);

      expect(
        notifier.shown.single.body,
        contains('will not stop while you are riding'),
      );
    });
  });

  group('sharing stopping on its own', () {
    test('is a notification, replacing the question', () async {
      await sync(SharingGuardPhase.prompting);

      await sync(
        SharingGuardPhase.paused,
        reason: SharingPauseReason.unanswered,
      );

      expect(notifier.shown, hasLength(2));
      expect(notifier.shown.last.title, 'Location sharing stopped');
      expect(notifier.shown.last.body, contains('Resume sharing'));
      expect(notifier.cleared, 0);
    });

    test('is shown once per pause', () async {
      for (var index = 0; index < 4; index += 1) {
        await sync(
          SharingGuardPhase.paused,
          reason: SharingPauseReason.unanswered,
        );
      }

      expect(notifier.shown, hasLength(1));
    });

    test('is not a notification when the rider chose it', () async {
      await sync(SharingGuardPhase.prompting);

      await sync(SharingGuardPhase.paused, reason: SharingPauseReason.rider);

      expect(notifier.shown, hasLength(1));
      expect(notifier.cleared, 1);
    });

    test('is not a notification while the rider is in the app', () async {
      await sync(
        SharingGuardPhase.paused,
        reason: SharingPauseReason.unanswered,
        foreground: true,
      );

      expect(notifier.shown, isEmpty);
    });

    test('is taken down when sharing resumes', () async {
      await sync(
        SharingGuardPhase.paused,
        reason: SharingPauseReason.unanswered,
      );

      await sync(SharingGuardPhase.sharing);

      expect(notifier.cleared, 1);
    });
  });

  group('when the ride is over', () {
    test('disposing takes down whatever is showing', () async {
      await sync(SharingGuardPhase.prompting);

      await presenter.dispose();

      expect(notifier.cleared, 1);
    });

    test('disposing with nothing showing says nothing', () async {
      await presenter.dispose();

      expect(notifier.cleared, 0);
    });
  });
}

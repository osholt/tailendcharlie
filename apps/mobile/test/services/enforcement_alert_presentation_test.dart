import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/enforcement_alert_presentation.dart';

void main() {
  group('announce briefly, then hold the border (#446)', () {
    test('the bubble is up for the first ten seconds', () {
      for (final elapsed in [
        Duration.zero,
        const Duration(seconds: 1),
        const Duration(seconds: 9, milliseconds: 999),
      ]) {
        expect(
          enforcementAlertStage(
            armed: true,
            dismissed: false,
            sinceArmed: elapsed,
          ),
          EnforcementAlertStage.announcing,
          reason: '$elapsed',
        );
      }
    });

    test('after ten seconds only the border holds', () {
      // The reported requirement, exactly: "display for a fixed 10 seconds and
      // then only the red border".
      for (final elapsed in [
        const Duration(seconds: 10),
        const Duration(seconds: 30),
        const Duration(minutes: 3),
      ]) {
        expect(
          enforcementAlertStage(
            armed: true,
            dismissed: false,
            sinceArmed: elapsed,
          ),
          EnforcementAlertStage.holding,
          reason: '$elapsed',
        );
      }
    });

    test('the life is fixed, not a function of distance', () {
      // A life tied to the distance never ends on a mile-long approach, which is
      // how the panel came to own the screen for the whole of it.
      expect(enforcementBubbleLife, const Duration(seconds: 10));
    });

    test('nothing is shown when no warning is armed', () {
      expect(
        enforcementAlertStage(
          armed: false,
          dismissed: false,
          sinceArmed: Duration.zero,
        ),
        EnforcementAlertStage.none,
      );
    });

    test('a dismissed warning shows nothing, border included', () {
      // Dismissing has to take the border too. A border with no bubble and no way
      // to clear it would be worse than the panel: permanent and unexplained.
      expect(
        enforcementAlertStage(
          armed: true,
          dismissed: true,
          sinceArmed: Duration.zero,
        ),
        EnforcementAlertStage.none,
      );
      expect(
        enforcementAlertStage(
          armed: true,
          dismissed: true,
          sinceArmed: const Duration(minutes: 1),
        ),
        EnforcementAlertStage.none,
      );
    });
  });

  group('the sign is enlarged for the whole approach', () {
    test('emphasis does not end with the bubble', () {
      // Deliberately independent of the ten seconds: the rider looks down after
      // the announcement, not during it, and a sign that shrank ten seconds
      // before the camera would be emphasis exactly where it was least useful.
      expect(enforcementEmphasisApplies(armed: true, dismissed: false), isTrue);
    });

    test('no warning, no emphasis', () {
      expect(
        enforcementEmphasisApplies(armed: false, dismissed: false),
        isFalse,
      );
      expect(enforcementEmphasisApplies(armed: true, dismissed: true), isFalse);
    });

    test('the change is big enough to notice', () {
      // The report was not that the emphasis was absent but that it was not
      // noticeable. Half again is the smallest step that reads as deliberate.
      expect(enforcementEmphasisScale, greaterThanOrEqualTo(1.4));
    });
  });

  group('the border does the work the full screen used to', () {
    test('it is wide enough to read as an alarm', () {
      // It is the entire warning after ten seconds, so it is not a highlight.
      expect(enforcementBorderWidth, greaterThanOrEqualTo(6));
    });
  });

  group('the bubble stays a notification', () {
    test('it is bounded well short of a landscape phone', () {
      // A full-width surface reads as a takeover even when it is short, which is
      // what #418's second attempt still was.
      expect(enforcementBubbleMaxWidth, lessThan(400));
    });
  });
}

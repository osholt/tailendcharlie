import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/navigation_guidance.dart';
import 'package:ride_relay/services/roundabout_exit_bucket.dart';

void main() {
  group('a roundabout exit is left, straight on, right or back (#427)', () {
    test('every stated direction lands in exactly one bucket', () {
      final buckets = {
        for (final direction in ManeuverDirection.values)
          direction: roundaboutExitBucket(direction),
      };

      expect(buckets[ManeuverDirection.sharpLeft], RoundaboutExitBucket.left);
      expect(buckets[ManeuverDirection.left], RoundaboutExitBucket.left);
      expect(buckets[ManeuverDirection.right], RoundaboutExitBucket.right);
      expect(buckets[ManeuverDirection.sharpRight], RoundaboutExitBucket.right);
      expect(buckets[ManeuverDirection.uTurn], RoundaboutExitBucket.back);
    });

    test('slight is straight on, both ways', () {
      // The ring offsets its own arms, so a crossing a rider calls straight
      // routinely shows 25-35 degrees of heading change from geometry alone —
      // which is why the roundabout straight band is already 38 rather than 20.
      // This follows the same reasoning one step further, and it is what absorbs
      // most of #412's "one off" error before it reaches a rider.
      expect(
        roundaboutExitBucket(ManeuverDirection.slightLeft),
        RoundaboutExitBucket.straightOn,
      );
      expect(
        roundaboutExitBucket(ManeuverDirection.straight),
        RoundaboutExitBucket.straightOn,
      );
      expect(
        roundaboutExitBucket(ManeuverDirection.slightRight),
        RoundaboutExitBucket.straightOn,
      );
    });

    test('an unstated direction claims nothing', () {
      // A roundabout with an exit number and no direction is still useful; a
      // made-up word is not.
      expect(roundaboutExitBucket(ManeuverDirection.unstated), isNull);
    });

    test(
      'a one-bucket error between slight and straight now changes nothing',
      () {
        // #412's reported shape: the direction is "either correct or one off". This
        // is the property that makes four buckets worth having.
        expect(
          roundaboutExitBucket(ManeuverDirection.slightRight),
          roundaboutExitBucket(ManeuverDirection.straight),
        );
        expect(
          roundaboutExitBucket(ManeuverDirection.sharpLeft),
          roundaboutExitBucket(ManeuverDirection.left),
        );
      },
    );

    test('a one-bucket error across a boundary still changes the word', () {
      // Honest about what this does not fix: straight against right is a real
      // difference and collapsing cannot hide it. #412 still needs its own fix.
      expect(
        roundaboutExitBucket(ManeuverDirection.straight),
        isNot(roundaboutExitBucket(ManeuverDirection.right)),
      );
    });

    test('every bucket is named in words a rider would use', () {
      for (final bucket in RoundaboutExitBucket.values) {
        expect(bucket.label.trim(), isNotEmpty, reason: '$bucket');
      }
      expect(RoundaboutExitBucket.straightOn.label, 'straight on');
    });
  });

  group('the drawn exit uses four fixed angles', () {
    test('left, ahead and right are square', () {
      expect(roundaboutExitBucketDegrees(RoundaboutExitBucket.left), -90);
      expect(roundaboutExitBucketDegrees(RoundaboutExitBucket.straightOn), 0);
      expect(roundaboutExitBucketDegrees(RoundaboutExitBucket.right), 90);
    });

    test('back is offset so it does not sit on the entry road', () {
      final back = roundaboutExitBucketDegrees(RoundaboutExitBucket.back);

      expect(back.abs(), lessThan(180));
      expect(back.abs(), greaterThan(150));
    });

    test('no two buckets draw the same arm', () {
      final angles = RoundaboutExitBucket.values
          .map(roundaboutExitBucketDegrees)
          .toSet();

      expect(angles, hasLength(RoundaboutExitBucket.values.length));
    });
  });
}

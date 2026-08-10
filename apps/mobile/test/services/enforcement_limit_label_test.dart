import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/fixed_speed_camera_catalogue.dart';

void main() {
  // The values below are the real ones. They come from counting the bundled
  // extract's `maxspeed` across all 3,480 cameras, not from imagining what OSM
  // might contain.
  group('the limit a camera enforces, where the extract says (#418)', () {
    test('a tagged mph limit is read out', () {
      expect(
        enforcementLimitLabel('Fixed camera · 50 mph limit'),
        '50 mph limit',
      );
    });

    test('no space before the unit still reads', () {
      // 3 of the 3,480 are tagged this way.
      expect(
        enforcementLimitLabel('Fixed camera · 50mph limit'),
        '50 mph limit',
      );
    });

    test('a variable limit says so rather than showing a number', () {
      // 8 cameras. A variable limit is exactly where a fixed number misleads.
      expect(
        enforcementLimitLabel('Average camera · Variable limit'),
        'VARIABLE LIMIT',
      );
    });

    test('an untagged camera shows nothing at all', () {
      // 1,685 of 3,480 — nearly half — carry no maxspeed. Silence has to be the
      // default, because a rider would act on a guessed number.
      expect(enforcementLimitLabel('Fixed camera'), isNull);
      expect(enforcementLimitLabel(''), isNull);
      expect(enforcementLimitLabel(null), isNull);
    });

    test('a bare number is not shown, because its unit is unknown', () {
      // `80`, `130`, `110` all appear, and the extract includes Irish cameras
      // (Garda Síochána is among the operators) where the limit is km/h. 80 km/h
      // and 80 mph are a long way apart, so neither may be guessed.
      expect(enforcementLimitLabel('Fixed camera · 80 limit'), isNull);
      expect(enforcementLimitLabel('Fixed camera · 130 limit'), isNull);
    });

    test('an explicit metric limit is read out with its unit', () {
      expect(
        enforcementLimitLabel('Fixed camera · 100 km/h limit'),
        '100 km/h limit',
      );
    });

    test("a rider's own sighting carries no limit and claims none", () {
      // Rider reports reach the same warning through the same details string.
      expect(
        enforcementLimitLabel('Reported by a rider 4 minutes ago'),
        isNull,
      );
    });
  });
}

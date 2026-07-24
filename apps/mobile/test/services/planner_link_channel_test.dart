import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/planner_link_channel.dart';

void main() {
  test('accepts the production planner URL and normalises its code', () {
    expect(
      planCodeFromPlannerLink(
        'https://tailendcharlie.app/planner.html?code=7f3k9qrt',
      ),
      '7F3K9QRT',
    );
  });

  test('rejects other origins, paths, fragments and ambiguous codes', () {
    expect(
      planCodeFromPlannerLink(
        'http://tailendcharlie.app/planner.html?code=7F3K9QRT',
      ),
      isNull,
    );
    expect(
      planCodeFromPlannerLink(
        'https://evil.example/planner.html?code=7F3K9QRT',
      ),
      isNull,
    );
    expect(
      planCodeFromPlannerLink('https://tailendcharlie.app/?code=7F3K9QRT'),
      isNull,
    );
    expect(
      planCodeFromPlannerLink(
        'https://tailendcharlie.app/planner.html?code=7F3K9QRT#route',
      ),
      isNull,
    );
    expect(
      planCodeFromPlannerLink(
        'https://tailendcharlie.app/planner.html?code=AAAA&code=BBBB',
      ),
      isNull,
    );
    expect(
      planCodeFromPlannerLink(
        'https://tailendcharlie.app/planner.html?code=bad-code',
      ),
      isNull,
    );
  });
}

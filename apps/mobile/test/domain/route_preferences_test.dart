import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/route_preferences.dart';

/// These fixtures are the web planner's own numbers, copied from
/// `apps/website/planner-core.mjs`. If either side changes, one of the two test
/// suites fails, which is what stops the app and the planner disagreeing about
/// what a preference means (#182).
void main() {
  group('route styles match the web planner contract', () {
    test('api values and detour limits are the planner values', () {
      expect(RouteStyle.values.map((style) => style.apiValue), [
        'quickest',
        'balanced',
        'twisty',
        'very-twisty',
      ]);
      expect(RouteStyle.quickest.detourLimit, 1);
      expect(RouteStyle.flowing.detourLimit, 1.25);
      expect(RouteStyle.twisty.detourLimit, 1.5);
      expect(RouteStyle.veryTwisty.detourLimit, 1.75);
    });

    test('only the quickest style declines alternatives', () {
      expect(RouteStyle.quickest.prefersBends, isFalse);
      expect(RouteStyle.flowing.prefersBends, isTrue);
      expect(RouteStyle.twisty.prefersBends, isTrue);
      expect(RouteStyle.veryTwisty.prefersBends, isTrue);
    });

    test('an unknown stored style falls back to quickest', () {
      expect(RouteStyle.fromApiValue('flowing'), isNull);
      expect(
        RoutePreferences.fromJson(const {'style': 'flowing'}).style,
        RouteStyle.quickest,
      );
    });
  });

  group('byway default', () {
    test('unsurfaced byways are avoided unless a rider says otherwise', () {
      expect(
        RoutePreferences.defaults.bywaySurface,
        BywaySurfacePreference.avoidUnsurfaced,
      );
      expect(RoutePreferences.defaults.bywaySurface.avoidsUnsurfaced, isTrue);
    });

    test(
      'a route with no recorded preference gets the road-biased default',
      () {
        expect(
          RoutePreferences.fromJson(const {}).bywaySurface,
          BywaySurfacePreference.avoidUnsurfaced,
        );
        expect(
          RoutePreferences.fromJson(const {
            'bywaySurface': 'nonsense',
          }).bywaySurface,
          BywaySurfacePreference.avoidUnsurfaced,
        );
      },
    );

    test('the summary always states which way round the byways are', () {
      expect(RoutePreferences.defaults.summary, 'Avoid unsurfaced byways.');
      expect(
        const RoutePreferences(
          bywaySurface: BywaySurfacePreference.allowUnsurfaced,
        ).summary,
        'Allow unsurfaced byways.',
      );
    });
  });

  group('engine choice matches requestRoadRoute in the web planner', () {
    test('defaults stay on OSRM', () {
      expect(RoutePreferences.defaults.requiresMotorcycleCosting, isFalse);
    });

    test('a bendier style alone stays on OSRM', () {
      for (final style in RouteStyle.values) {
        expect(
          RoutePreferences(style: style).requiresMotorcycleCosting,
          isFalse,
          reason: '${style.apiValue} needs only OSRM alternatives',
        );
      }
    });

    test('each avoidance moves to the motorcycle service', () {
      expect(
        const RoutePreferences(avoidMotorways: true).requiresMotorcycleCosting,
        isTrue,
      );
      expect(
        const RoutePreferences(avoidMajorRoads: true).requiresMotorcycleCosting,
        isTrue,
      );
      expect(
        const RoutePreferences(avoidTolls: true).requiresMotorcycleCosting,
        isTrue,
      );
      expect(
        const RoutePreferences(avoidFerries: true).requiresMotorcycleCosting,
        isTrue,
      );
    });

    test('seeking byways moves to the motorcycle service', () {
      // OSRM's car profile does not route highway=track at all, so this is the
      // byway case OSRM cannot serve.
      expect(
        const RoutePreferences(
          bywaySurface: BywaySurfacePreference.allowUnsurfaced,
        ).requiresMotorcycleCosting,
        isTrue,
      );
    });
  });

  group('Valhalla costing options match motorcycleCostingOptions', () {
    test('defaults', () {
      expect(RoutePreferences.defaults.valhallaMotorcycleCostingOptions(), {
        'use_highways': 1,
        'use_tolls': 0.5,
        'use_ferry': 0.5,
        'use_trails': 0,
        'exclude_highways': false,
        'exclude_tolls': false,
        'exclude_ferries': false,
        'exclude_unpaved': true,
      });
    });

    test('each style sets its own highway preference', () {
      expect(
        RouteStyle.values.map(
          (style) => RoutePreferences(
            style: style,
          ).valhallaMotorcycleCostingOptions()['use_highways'],
        ),
        [1, 0.6, 0.35, 0.15],
      );
    });

    test('avoiding major roads overrides the style highway preference', () {
      expect(
        const RoutePreferences(
          style: RouteStyle.veryTwisty,
          avoidMajorRoads: true,
        ).valhallaMotorcycleCostingOptions()['use_highways'],
        0.08,
      );
    });

    test('avoiding motorways excludes rather than penalises them', () {
      final options = const RoutePreferences(
        avoidMotorways: true,
      ).valhallaMotorcycleCostingOptions();
      expect(options['exclude_highways'], isTrue);
      // The motorway exclusion is independent of the twistiness setting.
      expect(options['use_highways'], 1);
    });

    test('allowing byways relaxes both surface levers together', () {
      final options = const RoutePreferences(
        bywaySurface: BywaySurfacePreference.allowUnsurfaced,
      ).valhallaMotorcycleCostingOptions();
      expect(options['use_trails'], 0.5);
      expect(options['exclude_unpaved'], isFalse);
    });

    test('the whole combination the issue asks for', () {
      expect(
        const RoutePreferences(
          style: RouteStyle.twisty,
          avoidMotorways: true,
        ).valhallaMotorcycleCostingOptions(),
        {
          'use_highways': 0.35,
          'use_tolls': 0.5,
          'use_ferry': 0.5,
          'use_trails': 0,
          'exclude_highways': true,
          'exclude_tolls': false,
          'exclude_ferries': false,
          'exclude_unpaved': true,
        },
      );
    });
  });

  test('preferences round-trip through JSON', () {
    const preferences = RoutePreferences(
      style: RouteStyle.veryTwisty,
      avoidMotorways: true,
      avoidMajorRoads: true,
      avoidTolls: true,
      avoidFerries: true,
      bywaySurface: BywaySurfacePreference.allowUnsurfaced,
    );

    expect(RoutePreferences.fromJson(preferences.toJson()), preferences);
    expect(preferences.toJson()['style'], 'very-twisty');
    expect(preferences.toJson()['bywaySurface'], 'allow-unsurfaced');
  });

  test('the requested notes read in the planner order', () {
    expect(
      const RoutePreferences(
        style: RouteStyle.flowing,
        avoidMotorways: true,
        avoidMajorRoads: true,
        avoidTolls: true,
        avoidFerries: true,
      ).requestedNotes,
      [
        'Flowing-road bias',
        'avoid motorways',
        'avoid major roads',
        'avoid toll roads',
        'avoid ferries',
        'avoid unsurfaced byways',
      ],
    );
  });

  test('the notes state what was asked and never claim an outcome', () {
    // They used to read "motorways excluded" and "unsurfaced byways avoided",
    // which a route up the M5 and a route over a gated track both went out
    // under (#858, #840). Whether a request was met is the verification's to
    // say, not the preference's.
    const everything = RoutePreferences(
      avoidMotorways: true,
      avoidMajorRoads: true,
      avoidTolls: true,
      avoidFerries: true,
    );
    for (final note in everything.requestedNotes) {
      expect(note, isNot(matches(RegExp(r'(excluded|avoided)$'))));
    }
  });
}

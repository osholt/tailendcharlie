import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/services/discovery_road_facts.dart';
import 'package:ride_relay/services/motorcycle_discovery.dart';

/// #160's acceptance criteria, one test each: every speed-limit provenance
/// state, the absent-data wording, and the visible difference between a pending
/// candidate and a researched one.
void main() {
  group('speed limit provenance', () {
    test('a tagged limit reads as a limit and says where it came from', () {
      final facts = _facts({
        'speedLimit': {'value': '60 mph', 'provenance': 'tagged'},
      });

      expect(facts.speedLimit, '60 mph');
      expect(facts.speedLimitIsKnown, isTrue);
      expect(facts.speedLimitProvenance, contains('Recorded in OpenStreetMap'));
    });

    test('a mixed tagged limit states its range rather than one number', () {
      final facts = _facts({
        'speedLimit': {
          'value': '50 mph',
          'provenance': 'tagged',
          'mixed': true,
          'range': ['40 mph', '60 mph'],
        },
      });

      expect(facts.speedLimit, '50 mph · varies from 40 mph to 60 mph');
      expect(facts.speedLimitIsKnown, isTrue);
    });

    test('an inferred limit is not presented as a posted value', () {
      final facts = _facts({
        'speedLimit': {
          'value': '60 mph',
          'provenance': 'inferred-from-maxspeed-type',
        },
      });

      expect(facts.speedLimit, '60 mph');
      expect(facts.speedLimitIsKnown, isTrue);
      expect(
        facts.speedLimitProvenance,
        'Implied by a national speed limit tag in OpenStreetMap, not a posted '
        'value for this road.',
      );
    });

    test('an unknown limit reads as not known, never as unrestricted', () {
      final facts = _facts({
        'speedLimit': {
          'value': null,
          'provenance': 'unknown',
          'note': 'OpenStreetMap does not record a limit for this road.',
        },
      });

      expect(facts.speedLimit, 'Speed limit not known');
      expect(facts.speedLimitIsKnown, isFalse);
      expect(
        facts.speedLimitProvenance,
        'OpenStreetMap does not record a limit for this road.',
      );
      // The two failure modes the issue names.
      expect(facts.speedLimit, isNot(contains('National')));
      expect(facts.speedLimit, isNot(contains('mph')));
    });

    test('an absent speedLimit field degrades to not known', () {
      final facts = _facts(const {});

      expect(facts.speedLimit, 'Speed limit not known');
      expect(facts.speedLimitIsKnown, isFalse);
      expect(
        facts.speedLimitProvenance,
        'A speed limit for this road is not recorded in OpenStreetMap.',
      );
    });

    test('an unknown limit with no note still explains itself', () {
      expect(
        _facts({
          'speedLimit': {'provenance': 'unknown'},
        }).speedLimitProvenance,
        contains(DiscoveryRoadFacts.notRecorded),
      );
    });

    test('a limit and an unknown limit are distinguishable', () {
      final tagged = _facts({
        'speedLimit': {'value': '60 mph', 'provenance': 'tagged'},
      });
      final unknown = _facts({
        'speedLimit': {'provenance': 'unknown'},
      });

      expect(tagged.speedLimit, isNot(unknown.speedLimit));
      expect(tagged.speedLimitIsKnown, isNot(unknown.speedLimitIsKnown));
    });
  });

  group('enforcement wording never overstates absence', () {
    test('no relation says "not recorded in OpenStreetMap", not "none"', () {
      final facts = _facts({
        'averageSpeedCheck': {'present': false},
        'fixedSpeedCameras': 0,
      });

      expect(
        facts.enforcement,
        'Average speed check: not recorded in OpenStreetMap for this road.',
      );
      expect(
        facts.fixedCameras,
        'Fixed speed cameras: not recorded in OpenStreetMap near this road.',
      );
      // Never the word "none", and never the final word: the caveat explains
      // that an absent record is not an absent camera.
      for (final line in facts.enforcementLines) {
        expect(line.toLowerCase(), isNot(contains('none')));
        expect(line.toLowerCase(), isNot(contains('no cameras')));
      }
      expect(
        facts.enforcementLines.last,
        DiscoveryRoadFacts.enforcementRecordCaveat,
      );
      expect(facts.hasRecordedEnforcement, isFalse);
    });

    test('an absent enforcement field reads the same honest way', () {
      final facts = _facts(const {});

      // Never looked is a weaker statement than looked and found nothing,
      // and the two are not collapsed into one.
      expect(
        facts.enforcement,
        'Average speed check: not checked for this road.',
      );
      expect(
        facts.fixedCameras,
        'Fixed speed cameras: not checked for this road.',
      );
      expect(
        facts.enforcementLines.last,
        DiscoveryRoadFacts.enforcementRecordCaveat,
      );
    });

    test('a present relation is stated plainly', () {
      final facts = _facts({
        'averageSpeedCheck': {
          'present': true,
          'relation': 'relation/18112962',
          'enforcedLimit': '50 mph',
        },
      });

      expect(
        facts.enforcement,
        'Average speed check: recorded in OpenStreetMap at 50 mph.',
      );
      expect(facts.hasRecordedEnforcement, isTrue);
      // Nothing to caveat when a relation really does cover the road.
      expect(
        facts.enforcementLines,
        isNot(contains(DiscoveryRoadFacts.enforcementRecordCaveat)),
      );
    });

    test('camera counts are singular and plural, and zero is not a count', () {
      expect(
        _facts({'fixedSpeedCameras': 1}).fixedCameras,
        'Fixed speed cameras: 1 recorded in OpenStreetMap near this road.',
      );
      expect(
        _facts({'fixedSpeedCameras': 3}).fixedCameras,
        'Fixed speed cameras: 3 recorded in OpenStreetMap near this road.',
      );
      expect(
        _facts({'fixedSpeedCameras': 0}).fixedCameras,
        contains(DiscoveryRoadFacts.notRecorded),
      );
    });

    test('a researched caveat is shown beside the OSM record', () {
      // The Snake Pass case the issue names: OSM records no relation, but
      // cameras have been publicly proposed.
      final facts = _facts({
        'averageSpeedCheck': {'present': false},
        'fixedSpeedCameras': 0,
        'enforcementNote':
            'The Peak District authority has considered average speed cameras '
            'here. OSM does not yet record an enforcement relation.',
      });

      expect(facts.enforcementCaveat, contains('considered average speed'));
      expect(facts.enforcementLines, hasLength(4));
      expect(facts.enforcementLines[2], facts.enforcementCaveat);
    });

    test('nothing invents a police-checks likelihood', () {
      final facts = _facts({
        'averageSpeedCheck': {'present': false},
        'fixedSpeedCameras': 0,
      });

      for (final line in [
        ...facts.enforcementLines,
        facts.busyPeriods,
        facts.speedLimitProvenance,
        facts.researchDetail,
      ]) {
        expect(line.toLowerCase(), isNot(contains('likely')));
        expect(line.toLowerCase(), isNot(contains('police check')));
      }
    });
  });

  group('busy periods and description', () {
    test('a researched busy period is shown as written', () {
      expect(
        _facts({
          'busyPeriods': 'Jams on summer weekends and bank holidays.',
        }).busyPeriods,
        'Jams on summer weekends and bank holidays.',
      );
    });

    test('an unresearched busy period says so rather than "quiet"', () {
      final facts = _facts(const {});

      expect(facts.busyPeriods, 'Busy periods have not been researched.');
      expect(facts.busyPeriods.toLowerCase(), isNot(contains('quiet')));
    });

    test('the rider description is optional', () {
      expect(_facts({'riderNote': 'A fine road.'}).description, 'A fine road.');
      expect(_facts(const {}).description, isNull);
      expect(_facts({'riderNote': '   '}).description, isNull);
    });
  });

  group('research status', () {
    test('a researched candidate is labelled and cites its sources', () {
      final facts = _facts({
        'researchStatus': 'researched',
        'evidenceSources': ['https://en.wikipedia.org/wiki/Horseshoe_Pass'],
      });

      expect(facts.isVerified, isTrue);
      expect(facts.researchLabel, 'Researched');
      expect(facts.researchDetail, contains('cited sources'));
      expect(facts.evidenceSources, hasLength(1));
    });

    test('a pending candidate is visibly distinguishable', () {
      final pending = _facts({'researchStatus': 'pending'});
      final researched = _facts({'researchStatus': 'researched'});

      expect(pending.isVerified, isFalse);
      expect(pending.researchLabel, 'Not yet reviewed');
      expect(pending.researchLabel, isNot(researched.researchLabel));
      expect(pending.researchDetail, isNot(researched.researchDetail));
      expect(pending.researchDetail, contains('not yet checked by a person'));
    });

    test('an unstated research status is no better than pending', () {
      final facts = _facts(const {});

      expect(facts.isVerified, isFalse);
      expect(facts.researchLabel, 'Not yet reviewed');
    });
  });

  test('the shipped catalogue parses its enrichment fields', () {
    // Guards the consumption contract rather than the data: #158 owns the
    // catalogue, and this only asserts that whatever it publishes is read.
    final catalogue = MotorcycleDiscoveryCatalogue.fromJson(
      jsonEncode({
        'type': 'FeatureCollection',
        'features': [
          _feature({
            'speedLimit': {
              'value': '50 mph',
              'provenance': 'tagged',
              'mixed': true,
              'range': ['40 mph', '60 mph'],
            },
            'averageSpeedCheck': {
              'present': true,
              'relation': 'relation/18112962',
            },
            'fixedSpeedCameras': 3,
            'busyPeriods': 'Commuter-heavy on weekdays.',
            'riderNote': 'A588 near Lower Thurnham.',
            'researchStatus': 'pending',
            'evidenceSources': ['https://example.test/a'],
          }),
        ],
      }),
    );
    final feature = catalogue.features.single;

    expect(feature.speedLimit.value, '50 mph');
    expect(feature.speedLimit.provenance, DiscoverySpeedLimitProvenance.tagged);
    expect(feature.speedLimit.range, ['40 mph', '60 mph']);
    expect(feature.averageSpeedCheck.present, isTrue);
    expect(feature.fixedSpeedCameras, 3);
    expect(feature.busyPeriods, 'Commuter-heavy on weekdays.');
    expect(feature.researchStatus, DiscoveryResearchStatus.pending);
    expect(feature.evidenceSources, ['https://example.test/a']);
  });

  test('a catalogue with no enrichment at all still loads', () {
    final catalogue = MotorcycleDiscoveryCatalogue.fromJson(
      jsonEncode({
        'type': 'FeatureCollection',
        'features': [_feature(const {})],
      }),
    );
    final feature = catalogue.features.single;

    expect(feature.speedLimit.provenance, DiscoverySpeedLimitProvenance.absent);
    expect(feature.averageSpeedCheck.recorded, isFalse);
    expect(feature.fixedSpeedCameras, isNull);
    expect(feature.researchStatus, DiscoveryResearchStatus.unstated);
  });
}

DiscoveryRoadFacts _facts(Map<String, Object?> properties) =>
    DiscoveryRoadFacts.of(
      MotorcycleDiscoveryCatalogue.fromJson(
        jsonEncode({
          'type': 'FeatureCollection',
          'features': [_feature(properties)],
        }),
      ).features.single,
    );

Map<String, Object?> _feature(Map<String, Object?> properties) => {
  'type': 'Feature',
  'geometry': {
    'type': 'LineString',
    'coordinates': [
      [-2.5, 53.9],
      [-2.49, 53.91],
    ],
  },
  'properties': {
    'id': 'test-road',
    'category': 'good_biking_road',
    'name': 'A588',
    'sourceName': 'OpenStreetMap via Geofabrik',
    'sourceUrl': 'https://www.openstreetmap.org/way/1',
    'confidence': 'medium',
    'lastVerified': '2026-07-24',
    'warning': 'Descriptive discovery hint only.',
    ...properties,
  },
};

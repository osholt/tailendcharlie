import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/map/discovery_road_sheet.dart';
import 'package:ride_relay/services/discovery_road_facts.dart';
import 'package:ride_relay/services/motorcycle_discovery.dart';

/// #160's app-side acceptance criteria: selecting a discovery road shows speed
/// limit, enforcement, busy periods and description, an unmapped limit reads
/// differently from a mapped one, and a pending candidate looks different from a
/// researched one.
void main() {
  testWidgets('a researched road shows every fact it has', (tester) async {
    await _pump(tester, {
      'speedLimit': {
        'value': '50 mph',
        'provenance': 'tagged',
        'mixed': true,
        'range': ['40 mph', '60 mph'],
      },
      'averageSpeedCheck': {'present': true, 'enforcedLimit': '50 mph'},
      'fixedSpeedCameras': 3,
      'busyPeriods': 'Jams on summer weekends and bank holidays.',
      'riderNote': 'A588 near Lower Thurnham, 92° of bend per km.',
      'researchStatus': 'researched',
      'evidenceSources': ['https://en.wikipedia.org/wiki/A588_road'],
    });

    expect(
      find.text('A588 near Lower Thurnham, 92° of bend per km.'),
      findsOneWidget,
    );
    expect(
      _rowHeadline(tester, 'discovery-speed-limit'),
      '50 mph · varies from 40 mph to 60 mph',
    );
    expect(
      _rowDetail(tester, 'discovery-enforcement'),
      contains('Average speed check: recorded in OpenStreetMap at 50 mph.'),
    );
    expect(
      _rowDetail(tester, 'discovery-enforcement'),
      contains('3 recorded in OpenStreetMap'),
    );
    expect(
      _rowDetail(tester, 'discovery-busy-periods'),
      'Jams on summer weekends and bank holidays.',
    );
    expect(_rowHeadline(tester, 'discovery-research-status'), 'Researched');
    // The cited source is reachable, listed by host.
    expect(find.text('en.wikipedia.org'), findsOneWidget);
  });

  testWidgets('an unmapped limit reads differently from a mapped one', (
    tester,
  ) async {
    await _pump(tester, {
      'speedLimit': {
        'provenance': 'unknown',
        'note': 'OpenStreetMap does not record a limit for this road.',
      },
    });
    final unknownStyle = _rowStyle(tester, 'discovery-speed-limit');
    final unknownIcon = _rowIcon(tester, 'discovery-speed-limit');

    expect(
      _rowHeadline(tester, 'discovery-speed-limit'),
      'Speed limit not known',
    );
    expect(
      _rowDetail(tester, 'discovery-speed-limit'),
      'OpenStreetMap does not record a limit for this road.',
    );
    expect(unknownStyle?.fontStyle, FontStyle.italic);
    expect(unknownIcon, Icons.help_outline);

    await _pump(tester, {
      'speedLimit': {'value': '60 mph', 'provenance': 'tagged'},
    });

    expect(_rowHeadline(tester, 'discovery-speed-limit'), '60 mph');
    expect(
      _rowStyle(tester, 'discovery-speed-limit')?.fontStyle,
      isNot(FontStyle.italic),
    );
    expect(_rowIcon(tester, 'discovery-speed-limit'), Icons.speed);
  });

  testWidgets('an inferred limit says it is not a posted value', (
    tester,
  ) async {
    await _pump(tester, {
      'speedLimit': {
        'value': '60 mph',
        'provenance': 'inferred-from-maxspeed-type',
      },
    });

    expect(_rowHeadline(tester, 'discovery-speed-limit'), '60 mph');
    expect(
      _rowDetail(tester, 'discovery-speed-limit'),
      contains('not a posted value for this road'),
    );
  });

  testWidgets('enforcement never says "none" and never ends on absence', (
    tester,
  ) async {
    await _pump(tester, {
      'averageSpeedCheck': {'present': false},
      'fixedSpeedCameras': 0,
    });
    final detail = _rowDetail(tester, 'discovery-enforcement');

    expect(detail, contains(DiscoveryRoadFacts.notRecorded));
    expect(detail.toLowerCase(), isNot(contains('none')));
    expect(detail, endsWith(DiscoveryRoadFacts.enforcementRecordCaveat));
  });

  testWidgets('a pending candidate is visibly distinguishable', (tester) async {
    await _pump(tester, {'researchStatus': 'pending'});
    final pendingBadge = _badgeColour(tester);

    expect(find.text('NOT YET REVIEWED'), findsOneWidget);
    expect(pendingBadge, DiscoveryResearchBadge.pendingForeground);
    expect(
      _rowDetail(tester, 'discovery-research-status'),
      contains('not yet checked by a person'),
    );

    await _pump(tester, {'researchStatus': 'researched'});

    expect(find.text('RESEARCHED'), findsOneWidget);
    expect(_badgeColour(tester), DiscoveryResearchBadge.verifiedForeground);
    expect(_badgeColour(tester), isNot(pendingBadge));
  });

  testWidgets('a bare candidate degrades honestly rather than reassuringly', (
    tester,
  ) async {
    await _pump(tester, const {});

    expect(
      _rowHeadline(tester, 'discovery-speed-limit'),
      'Speed limit not known',
    );
    expect(
      _rowDetail(tester, 'discovery-enforcement'),
      contains('not checked for this road'),
    );
    expect(
      _rowDetail(tester, 'discovery-busy-periods'),
      'Busy periods have not been researched.',
    );
    expect(find.text('NOT YET REVIEWED'), findsOneWidget);
    expect(find.byKey(const Key('discovery-description')), findsNothing);
  });

  testWidgets('no surface invents a police-checks likelihood', (tester) async {
    await _pump(tester, {
      'averageSpeedCheck': {'present': false},
      'fixedSpeedCameras': 0,
    });

    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      final value = (text.data ?? '').toLowerCase();
      expect(value, isNot(contains('likely')));
      expect(value, isNot(contains('police check')));
    }
  });

  testWidgets('the route action is disabled while a route is calculating', (
    tester,
  ) async {
    await _pump(tester, const {}, onAddToRoute: null);

    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('discovery-add-to-route')))
          .onPressed,
      isNull,
    );
  });
}

Future<void> _pump(
  WidgetTester tester,
  Map<String, Object?> properties, {
  VoidCallback? onAddToRoute = _noop,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: DiscoveryRoadSheet(
          feature: _feature(properties),
          onAddToRoute: onAddToRoute,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void _noop() {}

String _rowHeadline(WidgetTester tester, String key) => tester
    .widget<Text>(
      find
          .descendant(of: find.byKey(Key(key)), matching: find.byType(Text))
          .first,
    )
    .data!;

String _rowDetail(WidgetTester tester, String key) => tester
    .widget<Text>(
      find
          .descendant(of: find.byKey(Key(key)), matching: find.byType(Text))
          .at(1),
    )
    .data!;

TextStyle? _rowStyle(WidgetTester tester, String key) => tester
    .widget<Text>(
      find
          .descendant(of: find.byKey(Key(key)), matching: find.byType(Text))
          .first,
    )
    .style;

IconData? _rowIcon(WidgetTester tester, String key) => tester
    .widget<Icon>(
      find
          .descendant(of: find.byKey(Key(key)), matching: find.byType(Icon))
          .first,
    )
    .icon;

Color? _badgeColour(WidgetTester tester) => tester
    .widget<Text>(
      find
          .descendant(
            of: find.byKey(const Key('discovery-research-badge')),
            matching: find.byType(Text),
          )
          .first,
    )
    .style
    ?.color;

MotorcycleDiscoveryFeature _feature(Map<String, Object?> properties) =>
    MotorcycleDiscoveryCatalogue.fromJson(
      jsonEncode({
        'type': 'FeatureCollection',
        'features': [
          {
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
              'score': 81,
              ...properties,
            },
          },
        ],
      }),
    ).features.single;

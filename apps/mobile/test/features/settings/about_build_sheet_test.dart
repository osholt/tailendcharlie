import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/settings/about_build_sheet.dart';
import 'package:ride_relay/services/build_identity.dart';

void main() {
  const identity = BuildIdentity(
    appVersion: '1.0.1',
    appBuild: '137',
    track: DistributionTrack.playInternal,
    platform: TargetPlatform.android,
    relayHost: 'relay.tailendcharlie.app',
  );

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('shows the build identity a bug report needs', (tester) async {
    await tester.pumpWidget(
      wrap(
        AboutBuildSheet(
          identity: identity.copiedWithBuiltAt(DateTime.utc(2026, 7, 24)),
          lastRelaySync: DateTime.utc(2026, 7, 25, 9, 30),
          now: DateTime.utc(2026, 7, 25, 10),
        ),
      ),
    );

    expect(find.text('1.0.1'), findsOneWidget);
    expect(find.text('137'), findsOneWidget);
    expect(find.text('Play internal testing'), findsOneWidget);
    expect(find.text('relay.tailendcharlie.app'), findsOneWidget);
    expect(find.byKey(const Key('about-last-relay-sync')), findsOneWidget);
    expect(find.textContaining('30 min ago'), findsOneWidget);
  });

  testWidgets('never renders a full relay URL, only the host', (tester) async {
    await tester.pumpWidget(wrap(const AboutBuildSheet(identity: identity)));

    expect(find.textContaining('https://'), findsNothing);
    expect(find.textContaining('/api'), findsNothing);
  });

  testWidgets('says so plainly when no relay endpoint is configured', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const AboutBuildSheet(
          identity: BuildIdentity(
            appVersion: '1.0.1',
            appBuild: '137',
            track: DistributionTrack.local,
            platform: TargetPlatform.android,
          ),
        ),
      ),
    );

    expect(find.text('Not configured'), findsOneWidget);
    expect(find.text('No successful sync yet'), findsOneWidget);
  });

  testWidgets('offers a non-blocking update route on a stale build', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        AboutBuildSheet(
          identity: identity.copiedWithBuiltAt(DateTime.utc(2026, 6, 1)),
          now: DateTime.utc(2026, 7, 25),
        ),
      ),
    );

    expect(
      find.text('A newer tester build is probably available'),
      findsOneWidget,
    );
    expect(find.text('01/06/2026 · 54 days old'), findsOneWidget);
    expect(find.textContaining('This build is 54 days old'), findsOneWidget);
    expect(find.byKey(const Key('open-tester-update-channel')), findsOneWidget);
    expect(find.text('Open Google Play listing'), findsOneWidget);
  });

  testWidgets('confirms a fresh build without nagging', (tester) async {
    await tester.pumpWidget(
      wrap(
        AboutBuildSheet(
          identity: identity.copiedWithBuiltAt(DateTime.utc(2026, 7, 24)),
          now: DateTime.utc(2026, 7, 25),
        ),
      ),
    );

    expect(find.text('This is a current tester build'), findsOneWidget);
    expect(
      find.text('A newer tester build is probably available'),
      findsNothing,
    );
  });

  testWidgets('routes iOS testers to TestFlight instead of Play', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        AboutBuildSheet(
          identity: BuildIdentity(
            appVersion: '1.0.1',
            appBuild: '137',
            track: DistributionTrack.testFlight,
            platform: TargetPlatform.iOS,
            builtAt: DateTime.utc(2026, 6, 1),
            updateUri: Uri.parse('https://testflight.apple.com/'),
          ),
          now: DateTime.utc(2026, 7, 25),
        ),
      ),
    );

    expect(find.text('Open TestFlight'), findsOneWidget);
    expect(find.textContaining('pull to refresh'), findsOneWidget);
  });

  group('TesterUpdateBanner', () {
    testWidgets('stays out of the way while the build is current', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          TesterUpdateBanner(
            identity: identity.copiedWithBuiltAt(DateTime.utc(2026, 7, 24)),
            now: DateTime.utc(2026, 7, 25),
          ),
        ),
      );

      expect(find.byKey(const Key('tester-update-banner')), findsNothing);
    });

    testWidgets('never appears on an unstamped local build', (tester) async {
      await tester.pumpWidget(
        wrap(
          TesterUpdateBanner(
            identity: identity,
            now: DateTime.utc(2026, 7, 25),
          ),
        ),
      );

      expect(find.byKey(const Key('tester-update-banner')), findsNothing);
    });

    testWidgets('surfaces one obvious update action when stale', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          TesterUpdateBanner(
            identity: identity.copiedWithBuiltAt(DateTime.utc(2026, 6, 1)),
            now: DateTime.utc(2026, 7, 25),
          ),
        ),
      );

      expect(find.byKey(const Key('tester-update-banner')), findsOneWidget);
      expect(find.textContaining('1.0.1 (build 137)'), findsOneWidget);
      expect(
        find.byKey(const Key('tester-update-banner-open-channel')),
        findsOneWidget,
      );
    });
  });
}

extension on BuildIdentity {
  BuildIdentity copiedWithBuiltAt(DateTime builtAt) => BuildIdentity(
    appVersion: appVersion,
    appBuild: appBuild,
    track: track,
    platform: platform,
    builtAt: builtAt,
    relayHost: relayHost,
    updateUri: updateUri ?? BuildIdentity.defaultUpdateUriFor(platform),
    testerNotesUri: testerNotesUri,
    testerBuildLifetime: testerBuildLifetime,
  );
}

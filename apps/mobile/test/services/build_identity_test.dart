import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/features/settings/about_build_sheet.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/build_identity.dart';

void main() {
  group('BuildIdentity.fromEnvironment', () {
    test('reports exactly what the relay is told about this build', () {
      // The whole point of issue #101: the identity a tester reads in the app
      // must be the identity the relay receives. If either side changes its
      // dart-define name or fallback, this fails.
      final identity = BuildIdentity.fromEnvironment();
      final headers = RelayClientDescriptor.current().headers;

      expect(headers['x-tailendcharlie-app-version'], identity.appVersion);
      expect(headers['x-tailendcharlie-app-build'], identity.appBuild);
    });

    test('reports an unstamped build as unknown, never as a constant', () {
      // The field report was a build 28 artefact whose app claimed 1.0.1+22,
      // because both this class and the relay descriptor fell back to a
      // plausible-looking constant. An unstamped build must now say it does not
      // know. `flutter test --dart-define=RIDE_RELAY_APP_VERSION=9.9.9
      // --dart-define=RIDE_RELAY_APP_BUILD=4242` proves the stamped path.
      const stampedVersion = String.fromEnvironment('RIDE_RELAY_APP_VERSION');
      const stampedBuild = String.fromEnvironment('RIDE_RELAY_APP_BUILD');
      final identity = BuildIdentity.fromEnvironment();

      expect(
        identity.appVersion,
        stampedVersion.isEmpty
            ? RelayClientDescriptor.unknownVersion
            : stampedVersion,
      );
      expect(
        identity.appBuild,
        stampedBuild.isEmpty
            ? RelayClientDescriptor.unknownVersion
            : stampedBuild,
      );
      expect(identity.reportsVersion, stampedBuild.isNotEmpty);
      if (stampedBuild.isEmpty) {
        expect(identity.versionLabel, isNot(contains('1.0.1')));
        expect(identity.bugReportLine, isNot(contains('1.0.1+22')));
      }
    });

    // Proof that the workflow plumbing reaches the app. Skipped on an
    // unstamped run (plain `flutter test`); exercised by the command in
    // docs/android-internal-testing.md, which passes the same dart-defines the
    // release workflows pass.
    const stampedBuild = String.fromEnvironment('RIDE_RELAY_APP_BUILD');
    test(
      'a stamped build reports the stamped identity to the app and the relay',
      () {
        final identity = BuildIdentity.fromEnvironment();
        final headers = RelayClientDescriptor.current().headers;

        expect(identity.appBuild, stampedBuild);
        expect(headers['x-tailendcharlie-app-build'], stampedBuild);
        expect(
          identity.appVersion,
          const String.fromEnvironment('RIDE_RELAY_APP_VERSION'),
        );
        expect(
          headers['x-tailendcharlie-app-version'],
          const String.fromEnvironment('RIDE_RELAY_APP_VERSION'),
        );
        debugPrint(
          'stamped build identity: ${identity.bugReportLine} · '
          'built ${identity.builtAt} · relay ${identity.relayHost}',
        );
      },
      skip: stampedBuild.isEmpty
          ? 'Pass --dart-define=RIDE_RELAY_APP_BUILD=... to exercise the '
                'stamped release path.'
          : false,
    );

    test('defaults an unstamped build to the local track', () {
      const stampedTrack = String.fromEnvironment(
        'RIDE_RELAY_DISTRIBUTION_TRACK',
      );
      final identity = BuildIdentity.fromEnvironment();

      expect(
        identity.track,
        stampedTrack.isEmpty
            ? DistributionTrack.local
            : DistributionTrack.parse(stampedTrack),
      );
    });

    // The track equivalent of the guarded build-number proof above, and the
    // answer to defect 2 of #122: a build promoted to `alpha` must not tell its
    // testers they are on internal testing. Skipped on an unstamped run;
    // exercised by `flutter test --dart-define=RIDE_RELAY_DISTRIBUTION_TRACK=
    // alpha ...`, the command in docs/android-internal-testing.md.
    const stampedTrack = String.fromEnvironment(
      'RIDE_RELAY_DISTRIBUTION_TRACK',
    );
    testWidgets(
      'a stamped track reaches the About screen and the relay headers',
      (tester) async {
        final identity = BuildIdentity.fromEnvironment(
          platform: TargetPlatform.android,
        );
        final headers = RelayClientDescriptor.current().headers;

        expect(identity.track, DistributionTrack.parse(stampedTrack));
        expect(headers['x-tailendcharlie-distribution-track'], stampedTrack);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: AboutBuildSheet(identity: identity)),
          ),
        );

        expect(find.text(identity.track.label), findsOneWidget);
        expect(find.text(identity.updateActionLabel), findsOneWidget);
        debugPrint(
          'stamped track: ${identity.track.label} · header '
          '${headers['x-tailendcharlie-distribution-track']} · update '
          '${identity.updateUri}',
        );
      },
      skip: stampedTrack.isEmpty,
    );

    test('never exposes more of the relay endpoint than its host', () {
      final identity = BuildIdentity.fromEnvironment(
        platform: TargetPlatform.android,
      );

      expect(identity.relayHost, isNot(contains('/')));
      expect(identity.relayHost, isNot(contains('@')));
      expect(identity.relayHost, isNot(contains('?')));
    });
  });

  group('DistributionTrack.parse', () {
    test('maps the workflow track names onto tester-readable labels', () {
      expect(
        DistributionTrack.parse('internal'),
        DistributionTrack.playInternal,
      );
      expect(
        DistributionTrack.parse('alpha'),
        DistributionTrack.playClosedAlpha,
      );
      expect(DistributionTrack.parse('beta'), DistributionTrack.playClosedBeta);
      expect(
        DistributionTrack.parse('TestFlight'),
        DistributionTrack.testFlight,
      );
      expect(
        DistributionTrack.parse('ci'),
        DistributionTrack.continuousIntegration,
      );
      expect(DistributionTrack.parse(''), DistributionTrack.local);
      expect(
        DistributionTrack.parse('something-else'),
        DistributionTrack.local,
      );
      // The relay descriptor sanitises an unstamped define to `unknown`.
      expect(DistributionTrack.parse('unknown'), DistributionTrack.local);
    });

    test('separates the closed Play tracks testers are actually on', () {
      expect(DistributionTrack.playClosedAlpha.isPlayClosedTesting, isTrue);
      expect(DistributionTrack.playClosedBeta.isPlayClosedTesting, isTrue);
      expect(DistributionTrack.playInternal.isPlayClosedTesting, isFalse);
      expect(
        DistributionTrack.playClosedAlpha.label,
        'Play closed testing (alpha)',
      );
      expect(
        DistributionTrack.playClosedBeta.label,
        'Play closed testing (beta)',
      );
    });
  });

  group('update state', () {
    BuildIdentity identity({
      DateTime? builtAt,
      TargetPlatform platform = TargetPlatform.android,
    }) => BuildIdentity(
      appVersion: '1.2.3',
      appBuild: '44',
      track: DistributionTrack.playInternal,
      platform: platform,
      builtAt: builtAt,
      relayHost: 'relay.tailendcharlie.app',
      testerBuildLifetime: const Duration(days: 14),
    );

    test('is unknown when no build timestamp was stamped in', () {
      expect(
        identity().updateStateAt(DateTime.utc(2026, 7, 25)),
        TesterUpdateState.unknown,
      );
      expect(identity().ageInDaysAt(DateTime.utc(2026, 7, 25)), isNull);
    });

    test('is current inside the tester build lifetime', () {
      final subject = identity(builtAt: DateTime.utc(2026, 7, 20));

      expect(
        subject.updateStateAt(DateTime.utc(2026, 7, 25)),
        TesterUpdateState.current,
      );
      expect(subject.ageInDaysAt(DateTime.utc(2026, 7, 25)), 5);
    });

    test('flags a probably-newer build once the lifetime has elapsed', () {
      final subject = identity(builtAt: DateTime.utc(2026, 7, 1));

      expect(
        subject.updateStateAt(DateTime.utc(2026, 7, 25)),
        TesterUpdateState.newerBuildLikely,
      );
      expect(subject.ageInDaysAt(DateTime.utc(2026, 7, 25)), 24);
    });

    test('clamps a clock that runs behind the build timestamp', () {
      final subject = identity(builtAt: DateTime.utc(2026, 7, 25));

      expect(subject.ageInDaysAt(DateTime.utc(2026, 7, 20)), 0);
    });
  });

  group('tester update destinations', () {
    test('an Android internal build points at the Play listing', () {
      final uri = BuildIdentity.defaultUpdateUriFor(
        TargetPlatform.android,
        DistributionTrack.playInternal,
      )!;

      expect(uri.scheme, 'https');
      expect(uri.host, 'play.google.com');
      expect(uri.path, '/store/apps/details');
      expect(uri.queryParameters['id'], 'app.tailendcharlie');
    });

    test('a closed-track build points at the closed-testing opt-in page', () {
      // The store listing does not offer the app to a closed tester who has
      // not opted in on this device's Google account - the defect the #101
      // delivery investigation found.
      for (final track in [
        DistributionTrack.playClosedAlpha,
        DistributionTrack.playClosedBeta,
      ]) {
        final uri = BuildIdentity.defaultUpdateUriFor(
          TargetPlatform.android,
          track,
        )!;

        expect(uri.scheme, 'https');
        expect(uri.host, 'play.google.com');
        expect(uri.path, '/apps/testing/app.tailendcharlie');
        expect(uri.toString(), BuildIdentity.playClosedTestingOptInUrl);
      }
    });

    test('iOS points at TestFlight', () {
      final uri = BuildIdentity.defaultUpdateUriFor(
        TargetPlatform.iOS,
        DistributionTrack.testFlight,
      )!;

      expect(uri.scheme, 'https');
      expect(uri.host, 'testflight.apple.com');
    });

    test('track-specific update instructions name the right destination', () {
      const closed = BuildIdentity(
        appVersion: '1.0.1',
        appBuild: '137',
        track: DistributionTrack.playClosedAlpha,
        platform: TargetPlatform.android,
      );
      const internal = BuildIdentity(
        appVersion: '1.0.1',
        appBuild: '137',
        track: DistributionTrack.playInternal,
        platform: TargetPlatform.android,
      );

      expect(closed.updateInstruction, contains('closed-testing opt-in page'));
      expect(closed.updateActionLabel, 'Open closed testing page');
      expect(internal.updateInstruction, contains('Manage apps & device'));
      expect(internal.updateActionLabel, 'Open Google Play listing');
      expect(
        BuildIdentity.fromEnvironment(
          platform: TargetPlatform.iOS,
        ).updateInstruction,
        contains('TestFlight'),
      );
      expect(
        BuildIdentity.fromEnvironment(
          platform: TargetPlatform.iOS,
        ).updateActionLabel,
        'Open TestFlight',
      );
    });
  });

  group('bug-report identity', () {
    test('quotes version, build, track and platform on one line', () {
      const subject = BuildIdentity(
        appVersion: '1.0.1',
        appBuild: '123',
        track: DistributionTrack.playInternal,
        platform: TargetPlatform.android,
      );

      expect(subject.versionLabel, '1.0.1 (build 123)');
      expect(
        subject.bugReportLine,
        'Tail End Charlie 1.0.1+123 · Play internal testing · android',
      );
    });
  });
}

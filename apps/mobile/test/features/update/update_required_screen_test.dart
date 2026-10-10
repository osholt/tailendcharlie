import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/app_update_gate_controller.dart';
import 'package:ride_relay/controllers/internet_relay_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/internet/internet_relay_status_card.dart';
import 'package:ride_relay/features/update/update_required_screen.dart';
import 'package:ride_relay/internet/internet_cursor_store.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/internet/internet_relay_worker.dart';
import 'package:ride_relay/services/build_identity.dart';

final _relayUri = Uri.parse('https://tailendcharlie.app/update');

final _refused = UpdateGateState.updateRequired(
  message: 'Build 98 is older than the oldest build the ride service supports.',
  minimumBuild: 103,
  clientBuild: 98,
  // What the relay advertises. The build's own page must still win.
  relayUpdateUri: _relayUri,
);

void main() {
  // `BuildIdentity.updateUri` defaults per platform in `fromEnvironment`; the
  // const constructor leaves it null, so each test states the destination it
  // wants, exactly as the build channels do.
  BuildIdentity android({Uri? updateUri}) => BuildIdentity(
    appVersion: '1.0.1',
    appBuild: '98',
    track: DistributionTrack.playClosedAlpha,
    platform: TargetPlatform.android,
    updateUri:
        updateUri ??
        BuildIdentity.defaultUpdateUriFor(
          TargetPlatform.android,
          DistributionTrack.playClosedAlpha,
        ),
  );
  BuildIdentity ios() => BuildIdentity(
    appVersion: '1.0.1',
    appBuild: '98',
    track: DistributionTrack.testFlight,
    platform: TargetPlatform.iOS,
    updateUri: BuildIdentity.defaultUpdateUriFor(
      TargetPlatform.iOS,
      DistributionTrack.testFlight,
    ),
  );

  Future<List<Uri>> pumpScreen(
    WidgetTester tester,
    BuildIdentity identity, {
    UpdateGateState? state,
    double textScale = 1,
  }) async {
    final opened = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('open-screen'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => UpdateRequiredScreen(
                      identity: identity,
                      state: state ?? _refused,
                      openUri: (uri) async {
                        opened.add(uri);
                        return true;
                      },
                    ),
                  ),
                ),
                child: const Text('home'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-screen')));
    await tester.pumpAndSettle();
    return opened;
  }

  group('UpdateRequiredScreen', () {
    testWidgets('sends a closed-testing Android build to the opt-in page', (
      tester,
    ) async {
      final opened = await pumpScreen(tester, android());

      expect(find.text('Update required'), findsOneWidget);
      expect(
        find.text(
          'You have build 98. The ride service now needs build 103 or newer.',
        ),
        findsOneWidget,
      );
      expect(find.text('Open closed testing page'), findsOneWidget);
      expect(find.textContaining('closed-testing opt-in page'), findsOneWidget);

      await tester.tap(find.byKey(const Key('update-required-open')));
      await tester.pump();

      // The build's own track-aware page, not the relay's generic one.
      expect(opened, [Uri.parse(BuildIdentity.playClosedTestingOptInUrl)]);
    });

    testWidgets('sends an iOS build to TestFlight', (tester) async {
      final opened = await pumpScreen(tester, ios());

      expect(find.text('Open TestFlight'), findsOneWidget);
      expect(
        find.textContaining('Open TestFlight and pull to refresh'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('update-required-open')));
      await tester.pump();

      expect(opened, [Uri.parse(BuildIdentity.testFlightUrl)]);
    });

    testWidgets(
      'uses a build-specific TestFlight invitation when one was stamped in',
      (tester) async {
        final invitation = Uri.parse(
          'https://testflight.apple.com/join/example',
        );
        final opened = await pumpScreen(
          tester,
          BuildIdentity(
            appVersion: '1.0.1',
            appBuild: '98',
            track: DistributionTrack.testFlight,
            platform: TargetPlatform.iOS,
            updateUri: invitation,
          ),
        );

        await tester.tap(find.byKey(const Key('update-required-open')));
        await tester.pump();

        expect(opened, [invitation]);
      },
    );

    testWidgets(
      'falls back to the relay link for a build with no destination of its own',
      (tester) async {
        final opened = await pumpScreen(
          tester,
          const BuildIdentity(
            appVersion: '1.0.1',
            appBuild: '98',
            track: DistributionTrack.local,
            platform: TargetPlatform.linux,
          ),
          state: UpdateGateState.updateRequired(relayUpdateUri: _relayUri),
        );

        await tester.tap(find.byKey(const Key('update-required-open')));
        await tester.pump();

        expect(opened, [_relayUri]);
      },
    );

    testWidgets(
      'with no link anywhere it still explains, without a dead button',
      (tester) async {
        await pumpScreen(
          tester,
          const BuildIdentity(
            appVersion: '1.0.1',
            appBuild: '98',
            track: DistributionTrack.local,
            platform: TargetPlatform.linux,
          ),
          state: const UpdateGateState.updateRequired(),
        );

        expect(find.byKey(const Key('update-required-open')), findsNothing);
        expect(
          find.byKey(const Key('update-required-version')),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          find.byKey(const Key('update-required-continue')),
          200,
        );
        expect(
          find.byKey(const Key('update-required-continue')),
          findsOneWidget,
        );
      },
    );

    testWidgets('names the build when the minimum is not known', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        android(),
        state: const UpdateGateState.updateRequired(),
      );

      expect(find.text('You have 1.0.1 (build 98).'), findsOneWidget);
    });

    testWidgets('says plainly what is and is not switched off', (tester) async {
      await pumpScreen(tester, android());

      final scope = find.byKey(const Key('update-required-scope'));
      await tester.scrollUntilVisible(scope, 200);
      expect(
        find.descendant(of: scope, matching: find.text('Not switched off')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: scope,
          matching: find.textContaining('SOS and the alert buttons'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: scope,
          matching: find.text('Paused until you update'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: scope,
          matching: find.textContaining(
            'will not reach riders through the ride service',
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('can always be left: continue, and the close button', (
      tester,
    ) async {
      await pumpScreen(tester, android());
      await tester.scrollUntilVisible(
        find.byKey(const Key('update-required-continue')),
        200,
      );
      await tester.tap(find.byKey(const Key('update-required-continue')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('update-required-screen')), findsNothing);
      expect(find.text('home'), findsOneWidget);

      await tester.tap(find.byKey(const Key('open-screen')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('update-required-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('update-required-screen')), findsNothing);
    });

    testWidgets('fits a small phone at the largest text size', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pumpScreen(tester, android(), textScale: 2);

      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.byKey(const Key('update-required-continue')),
        200,
      );
      expect(find.byKey(const Key('update-required-continue')), findsOneWidget);
    });
  });

  group('UpdateRequiredBanner', () {
    testWidgets('appears only while the relay refuses this build', (
      tester,
    ) async {
      final gate = AppUpdateGateController(checkCompatibility: null);
      addTearDown(gate.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UpdateRequiredBanner(gate: gate, identity: android()),
          ),
        ),
      );
      expect(find.byKey(const Key('update-required-banner')), findsNothing);

      gate.apply(_result(RelayCompatibilityDisposition.updateRequired));
      await tester.pump();
      expect(find.byKey(const Key('update-required-banner')), findsOneWidget);
      expect(
        find.textContaining(
          'SOS and everything else on this phone keeps working',
        ),
        findsOneWidget,
      );

      gate.apply(_result(RelayCompatibilityDisposition.compatible));
      await tester.pump();
      expect(find.byKey(const Key('update-required-banner')), findsNothing);
    });

    testWidgets('opens the right page, or the explanation', (tester) async {
      final gate = AppUpdateGateController(checkCompatibility: null)
        ..apply(_result(RelayCompatibilityDisposition.updateRequired));
      addTearDown(gate.dispose);
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UpdateRequiredBanner(
              gate: gate,
              identity: ios(),
              openUri: (uri) async {
                opened.add(uri);
                return true;
              },
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('update-required-banner-open')));
      await tester.pump();
      expect(opened, [Uri.parse(BuildIdentity.testFlightUrl)]);

      await tester.tap(find.byKey(const Key('update-required-banner-details')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('update-required-screen')), findsOneWidget);
    });
  });

  group('InternetRelayStatusCard while the relay refuses this build', () {
    Future<InternetRelayController> refused(WidgetTester tester) async {
      final controller = InternetRelayController(
        InternetRelayWorker(
          api: _RefusingApi(_relayUri),
          eventStore: InMemoryEventStore(),
          cursorStore: InMemoryInternetCursorStore(),
          pollInterval: const Duration(hours: 1),
          retryPolicy: const InternetRetryPolicy(
            initialDelay: Duration(hours: 1),
            maximumDelay: Duration(hours: 1),
          ),
        ),
      );
      await tester.runAsync(() async {
        await controller.start(_session);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      addTearDown(() async => tester.runAsync(controller.close));
      return controller;
    }

    testWidgets('names the update, the right page, and what is unaffected', (
      tester,
    ) async {
      final controller = await refused(tester);
      final opened = <Uri>[];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InternetRelayStatusCard(
              controller: controller,
              identity: android(),
              openUri: (uri) async {
                opened.add(uri);
                return true;
              },
            ),
          ),
        ),
      );

      expect(find.text('App update required'), findsOneWidget);
      expect(
        find.textContaining('SOS, alerts and navigation are not affected'),
        findsOneWidget,
      );
      final button = tester.widget<IconButton>(
        find.byKey(const Key('open-required-update')),
      );
      expect(button.tooltip, 'Open closed testing page');

      await tester.tap(find.byKey(const Key('open-required-update')));
      await tester.pump();

      expect(opened, [Uri.parse(BuildIdentity.playClosedTestingOptInUrl)]);
    });
  });
}

RelayCompatibilityResult _result(RelayCompatibilityDisposition disposition) =>
    RelayCompatibilityResult(
      disposition: disposition,
      serverProtocol: 1,
      minimumClientProtocol: 1,
      capabilities: const {},
      checkedAt: DateTime.utc(2026, 10, 9),
      validUntil: DateTime.utc(2026, 10, 9, 0, 5),
      minimumClientBuild: 103,
      clientBuild: 98,
    );

/// A relay that has retired this build: the compatibility check says so and no
/// sync is ever reached.
class _RefusingApi implements InternetRelayApi, RelayCompatibilityApi {
  _RefusingApi(this.updateUri);

  final Uri updateUri;

  @override
  InternetRelayConfiguration get configuration =>
      InternetRelayConfiguration(baseUri: Uri.parse('https://relay.example'));

  @override
  Future<RelayCompatibilityResult>
  checkCompatibility() async => RelayCompatibilityResult(
    disposition: RelayCompatibilityDisposition.updateRequired,
    serverProtocol: 1,
    minimumClientProtocol: 1,
    capabilities: const {},
    checkedAt: DateTime.utc(2026, 10, 9),
    validUntil: DateTime.utc(2026, 10, 9, 0, 5),
    message:
        'Build 98 is older than the oldest build the ride service supports (103).',
    updateUri: updateUri,
    minimumClientBuild: 103,
    clientBuild: 98,
  );

  @override
  Future<InternetSyncResult> synchronize({
    required RideSession session,
    required String? cursor,
    required List<RideEvent> events,
  }) => throw StateError('A refused build must not reach the sync endpoint.');

  @override
  void close() {}
}

final _session = RideSession(
  rideId: 'ride-alpha',
  rideCode: 'ALPHA1',
  inviteSecret: '0123456789abcdef0123456789abcdef',
  joinToken: 'test-join-token-0123456789',
  localRiderId: 'local-device',
  displayName: 'Oliver',
  role: RideRole.rider,
  joinedAt: DateTime.utc(2026, 10, 9),
);

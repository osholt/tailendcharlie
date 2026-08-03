import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/app/ride_invitation_link_gate.dart';
import 'package:ride_relay/controllers/ride_code_preference_controller.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/controllers/ride_invitation_link_controller.dart';
import 'package:ride_relay/controllers/rider_profile_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/nearby_bridge.dart';
import 'package:ride_relay/services/ride_invitation_link.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'rider_profile_display_name': 'Sam',
      'rider_profile_onboarding_completed': true,
    });
  });

  testWidgets(
    'a confirmed link joins through the authenticated directory path',
    (tester) async {
      const token = 'Abcdefghijklmnop12345678';
      final directory = _Directory(
        expectedCode: '123456',
        expectedToken: token,
      );
      final fixture = await _Fixture.create(
        directory: directory,
        link: rideInvitationUrl('123456', token),
      );
      addTearDown(fixture.dispose);

      await tester.pumpWidget(fixture.app);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Join ride 123456?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('accept-ride-invitation-link')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(directory.seenToken, token);
      expect(fixture.rideController.session?.rideCode, '123456');
      expect(fixture.rideController.session?.inviteSecret, directory.secret);
      expect(fixture.links.hasNotice, isFalse);
    },
  );

  testWidgets('an invitation cannot silently replace an active ride', (
    tester,
  ) async {
    final fixture = await _Fixture.create(
      directory: _Directory(
        expectedCode: '654321',
        expectedToken: 'ZYXWVUTSRQPONMLK12345678',
      ),
      link: rideInvitationUrl('654321', 'ZYXWVUTSRQPONMLK12345678'),
    );
    addTearDown(fixture.dispose);
    await fixture.rideController.createRide('Sam');
    final currentRideId = fixture.rideController.session!.rideId;

    await tester.pumpWidget(fixture.app);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('A ride is already open'), findsOneWidget);
    expect(find.textContaining('cannot replace it silently'), findsOneWidget);
    await tester.tap(find.text('Keep current ride'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(fixture.rideController.session?.rideId, currentRideId);
    expect(fixture.links.hasNotice, isFalse);
  });

  testWidgets('a malformed link explains the problem and does not join', (
    tester,
  ) async {
    final fixture = await _Fixture.create(
      directory: _Directory(
        expectedCode: '123456',
        expectedToken: 'Abcdefghijklmnop12345678',
      ),
      link: 'https://tailendcharlie.app/join.html#broken',
    );
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.app);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Cannot open invitation'), findsOneWidget);
    expect(find.textContaining('incomplete or malformed'), findsOneWidget);
    expect(fixture.rideController.hasActiveRide, isFalse);
  });

  testWidgets('an inactive or revoked invitation gets a plain explanation', (
    tester,
  ) async {
    const token = 'Abcdefghijklmnop12345678';
    final fixture = await _Fixture.create(
      directory: const _RejectingDirectory(),
      link: rideInvitationUrl('123456', token),
    );
    addTearDown(fixture.dispose);

    await tester.pumpWidget(fixture.app);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('accept-ride-invitation-link')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Could not join this ride'), findsOneWidget);
    expect(find.textContaining('no longer active'), findsOneWidget);
    expect(fixture.rideController.hasActiveRide, isFalse);
  });
}

class _Fixture {
  const _Fixture({
    required this.rideController,
    required this.links,
    required this.profile,
    required this.preference,
  });

  final RideController rideController;
  final RideInvitationLinkController links;
  final RiderProfileController profile;
  final RideCodePreferenceController preference;

  static Future<_Fixture> create({
    required RideCodeDirectory directory,
    required String link,
  }) async {
    final rideController = RideController(
      InMemoryEventStore(),
      InMemorySessionStore(),
      const _FakeNearbyBridge(),
      rideCodeDirectory: directory,
    );
    await rideController.initialize();
    return _Fixture(
      rideController: rideController,
      links: await RideInvitationLinkController.load(
        source: _OneLinkSource(link),
      ),
      profile: await RiderProfileController.load(),
      preference: RideCodePreferenceController.memory(),
    );
  }

  Widget get app => MaterialApp(
    home: RideInvitationLinkGate(
      links: links,
      rideController: rideController,
      rideCodePreference: preference,
      riderProfile: profile,
      ready: true,
      child: const Scaffold(body: Text('Ready')),
    ),
  );

  void dispose() {
    links.dispose();
    rideController.dispose();
    profile.dispose();
    preference.dispose();
  }
}

class _OneLinkSource implements IncomingRideInvitationLinkSource {
  _OneLinkSource(this.value);

  String? value;

  @override
  Future<String?> consumePending() async {
    final current = value;
    value = null;
    return current;
  }
}

class _Directory implements RideCodeDirectory {
  _Directory({required this.expectedCode, required this.expectedToken});

  final String expectedCode;
  final String expectedToken;
  final String secret = 'ride-secret-abcdefghijklmnop';
  String? seenToken;

  @override
  Future<RideCodeCredentials> resolve(
    String rideCode, {
    String? joinToken,
  }) async {
    expect(rideCode, expectedCode);
    expect(joinToken, expectedToken);
    seenToken = joinToken;
    return RideCodeCredentials(
      rideId: 'ride-$rideCode',
      rideCode: rideCode,
      inviteSecret: secret,
      joinToken: expectedToken,
    );
  }

  @override
  Future<void> register(RideSession session) async {}

  @override
  void close() {}
}

class _RejectingDirectory implements RideCodeDirectory {
  const _RejectingDirectory();

  @override
  Future<RideCodeCredentials> resolve(
    String rideCode, {
    String? joinToken,
  }) async => throw const RideCodeDirectoryException(
    'That ride invitation is no longer active. Ask the ride lead for a new one.',
  );

  @override
  Future<void> register(RideSession session) async {}

  @override
  void close() {}
}

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async =>
      const NearbyCapabilities.unavailable();
}

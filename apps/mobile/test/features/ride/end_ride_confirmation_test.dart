import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_controller.dart';
import 'package:ride_relay/data/in_memory_event_store.dart';
import 'package:ride_relay/data/in_memory_session_store.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/features/ride/end_ride_confirmation.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/services/nearby_bridge.dart';

/// Ending a ride stops the group, not just this phone, and it was reachable two
/// ways with a different dialog behind each (#306: "every destructive or safety
/// action reachable by the same gesture every time").
///
/// The two were not merely worded differently. Only the ride menu's told the
/// leader whether the ride could be resumed — including "this action cannot be
/// undone for the group" when the relay cannot carry a reopen. Only the
/// dashboard's showed the marking summary and offered to share it. So **whether
/// a leader learned that ending the ride was irreversible depended on which
/// button they happened to press.**
void main() {
  group('the consequence is stated once, for both entry points', () {
    test('a reopenable ride says it can be resumed', () {
      final text = endRideConsequence(relayCanCarryReopen: true);

      expect(text, contains('ends the group ride for everyone'));
      expect(text, contains('resume it within 24 hours'));
      expect(text, isNot(contains('cannot be undone')));
    });

    test('a ride that cannot be reopened says it cannot be undone', () {
      // The sentence the dashboard's dialog never had, and the one a leader
      // needs most.
      final text = endRideConsequence(relayCanCarryReopen: false);

      expect(text, contains('cannot resume an ended ride'));
      expect(text, contains('cannot be undone for the group'));
      expect(text, isNot(contains('within 24 hours')));
    });

    test('both readings name the group, not just this phone', () {
      // The dashboard's old wording led with "Location sharing will stop on
      // this phone", which understates an action that ends everyone's ride.
      for (final reopenable in [true, false]) {
        expect(
          endRideConsequence(relayCanCarryReopen: reopenable),
          contains('for everyone'),
          reason: 'relayCanCarryReopen: $reopenable',
        );
      }
    });

    test('the two readings differ only in whether it can be undone', () {
      // If they diverged anywhere else, the two entry points would be back to
      // telling a leader different things about the same action.
      final reopenable = endRideConsequence(relayCanCarryReopen: true);
      final permanent = endRideConsequence(relayCanCarryReopen: false);
      String head(String text) => text.split('\n\n').first;

      expect(head(reopenable), head(permanent));
      expect(reopenable, isNot(permanent));
    });
  });

  group('who may end the ride for everyone', () {
    // Three surfaces offered this and expressed the condition three ways, two
    // of them wrong. `RideController.endRide` accepts `isLocalRideLeader`; the
    // shell's end-ride guard and the map's exit dialog both read
    // `session?.role == RideRole.lead`, which is a different thing.
    Future<RideController> controllerFor({required bool marking}) async {
      var id = 0;
      final controller = RideController(
        InMemoryEventStore(),
        InMemorySessionStore(),
        const _FakeNearbyBridge(),
        clock: () => DateTime.utc(2026, 8, 3, 9),
        idFactory: () => 'id-${id++}',
        random: Random(3),
        rideCodeDirectory: _OfflineRideCodeDirectory(),
      );
      await controller.initialize();
      await controller.createRide('Oliver');
      await controller.startRide();
      if (marking) await controller.startMarker();
      return controller;
    }

    test('a leader may', () async {
      final controller = await controllerFor(marking: false);
      addTearDown(controller.dispose);

      expect(controller.session?.role, RideRole.lead);
      expect(canEndRideForEveryone(controller), isTrue);
    });

    test('a leader currently acting as the marker may', () async {
      // The case the two wrong expressions refused. `endRide` would have
      // accepted it, so refusing it meant the app offering an action and then
      // doing nothing.
      final controller = await controllerFor(marking: true);
      addTearDown(controller.dispose);

      expect(
        controller.session?.role,
        isNot(RideRole.lead),
        reason: 'the precondition: marking changes the session role',
      );
      expect(canEndRideForEveryone(controller), isTrue);
    });

    test('the decision matches what the controller will accept', () async {
      // If these ever diverge again, one surface offers what another refuses.
      for (final marking in [false, true]) {
        final controller = await controllerFor(marking: marking);
        addTearDown(controller.dispose);
        expect(
          canEndRideForEveryone(controller),
          controller.isLocalRideLeader,
          reason: 'marking: $marking',
        );
      }
    });
  });

  // #362: the consequence text named a group, and other phones, that a solo
  // ride does not have.
  test('a solo ride is not ended for everyone', () {
    final solo = endRideConsequence(relayCanCarryReopen: true, isSolo: true);

    expect(solo, contains('This ends your ride.'));
    expect(solo, isNot(contains('everyone')));
    expect(solo, isNot(contains('group')));
    expect(solo, contains('resume it within 24 hours'));

    final soloWithoutReopen = endRideConsequence(
      relayCanCarryReopen: false,
      isSolo: true,
    );
    expect(soloWithoutReopen, isNot(contains('other phones')));
    expect(soloWithoutReopen, contains('cannot be undone'));

    // The group wording is untouched.
    expect(
      endRideConsequence(relayCanCarryReopen: true),
      contains('for everyone'),
    );
  });
}

class _FakeNearbyBridge extends NearbyBridge {
  const _FakeNearbyBridge();

  @override
  Future<NearbyCapabilities> capabilities() async =>
      const NearbyCapabilities.unavailable();
}

class _OfflineRideCodeDirectory implements RideCodeDirectory {
  @override
  Future<void> register(RideSession session) async {}

  @override
  Future<RideCodeCredentials> resolve(
    String rideCode, {
    String? joinToken,
  }) async => throw const RideCodeDirectoryException('Offline in tests.');

  @override
  void close() {}
}

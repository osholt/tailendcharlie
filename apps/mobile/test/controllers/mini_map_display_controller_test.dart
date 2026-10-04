import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/mini_map_display_controller.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// #850: the group mini-map is on by default for the leader and the Tail End
/// Charlie and off for everyone else, the default follows the role as it
/// changes, and a rider's own choice outranks it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the default for a role', () {
    test('is on for the leader and the Tail End Charlie only', () {
      expect(miniMapVisibleByDefault(RideRole.lead), isTrue);
      expect(miniMapVisibleByDefault(RideRole.tailEndCharlie), isTrue);
      expect(miniMapVisibleByDefault(RideRole.rider), isFalse);
      expect(miniMapVisibleByDefault(RideRole.marker), isFalse);
    });

    test('reads a rider with no role yet as a follower', () {
      expect(miniMapVisibleByDefault(null), isFalse);
    });
  });

  group('the decision, role by explicit choice', () {
    // Every role, including none, against every state of the setting: nothing
    // chosen, chosen on, chosen off. The cell that matters is the second and
    // third columns: a choice is the rider's whatever their role says.
    final roles = <RideRole?>[null, ...RideRole.values];
    for (final role in roles) {
      test('${role?.name ?? 'no role'}: nothing chosen follows the role', () {
        expect(
          miniMapVisible(role: role, explicitChoice: null),
          miniMapVisibleByDefault(role),
        );
      });
      test('${role?.name ?? 'no role'}: chosen on is on', () {
        expect(miniMapVisible(role: role, explicitChoice: true), isTrue);
      });
      test('${role?.name ?? 'no role'}: chosen off is off', () {
        expect(miniMapVisible(role: role, explicitChoice: false), isFalse);
      });
    }
  });

  group('the controller', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test(
      'has made no choice on a fresh install, so the role decides',
      () async {
        final controller = await MiniMapDisplayController.load();
        addTearDown(controller.dispose);

        expect(controller.explicitChoice, isNull);
        expect(controller.hasExplicitChoice, isFalse);
        expect(controller.visibleFor(RideRole.lead), isTrue);
        expect(controller.visibleFor(RideRole.rider), isFalse);
      },
    );

    test('follows the role live while the rider has chosen nothing', () async {
      final controller = await MiniMapDisplayController.load();
      addTearDown(controller.dispose);

      // The same controller, asked as the rider is handed the lead and then hands
      // it on: no restart, no re-reading of anything.
      expect(controller.visibleFor(RideRole.rider), isFalse);
      expect(controller.visibleFor(RideRole.lead), isTrue);
      expect(controller.visibleFor(RideRole.tailEndCharlie), isTrue);
      expect(controller.visibleFor(RideRole.rider), isFalse);
    });

    test('a choice to show wins for a follower, in every role', () async {
      final controller = await MiniMapDisplayController.load();
      addTearDown(controller.dispose);

      await controller.setVisible(true);

      for (final role in [null, ...RideRole.values]) {
        expect(
          controller.visibleFor(role),
          isTrue,
          reason: '${role?.name ?? 'no role'} chose to show it',
        );
      }
    });

    test('a choice to hide wins for the leader, in every role', () async {
      final controller = await MiniMapDisplayController.load();
      addTearDown(controller.dispose);

      await controller.setVisible(false);

      for (final role in [null, ...RideRole.values]) {
        expect(
          controller.visibleFor(role),
          isFalse,
          reason: '${role?.name ?? 'no role'} chose to hide it',
        );
      }
    });

    test('remembers a choice across a restart, on or off', () async {
      for (final choice in [true, false]) {
        SharedPreferences.setMockInitialValues({});
        final first = await MiniMapDisplayController.load();
        await first.setVisible(choice);
        first.dispose();

        final restored = await MiniMapDisplayController.load();
        addTearDown(restored.dispose);
        expect(restored.explicitChoice, choice);
        expect(restored.hasExplicitChoice, isTrue);
        expect(
          restored.visibleFor(choice ? RideRole.rider : RideRole.lead),
          choice,
        );
      }
    });

    test('stores the choice, never the default it overrode', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = await MiniMapDisplayController.load();
      addTearDown(controller.dispose);

      // Asking as a leader, and as a follower, decides nothing for next time.
      controller.visibleFor(RideRole.lead);
      controller.visibleFor(RideRole.rider);

      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.containsKey(MiniMapDisplayController.preferenceKey),
        false,
      );
    });

    test('returning to the role default forgets the choice for good', () async {
      final controller = await MiniMapDisplayController.load();
      await controller.setVisible(true);
      await controller.useRoleDefault();
      controller.dispose();

      final restored = await MiniMapDisplayController.load();
      addTearDown(restored.dispose);
      expect(restored.explicitChoice, isNull);
      expect(restored.visibleFor(RideRole.rider), isFalse);
      expect(restored.visibleFor(RideRole.lead), isTrue);
    });

    test('tells its listeners about a change and not about a repeat', () async {
      final controller = await MiniMapDisplayController.load();
      addTearDown(controller.dispose);
      var notified = 0;
      controller.addListener(() => notified += 1);

      await controller.useRoleDefault();
      expect(notified, 0, reason: 'there was no choice to forget');

      await controller.setVisible(true);
      await controller.setVisible(true);
      expect(notified, 1);

      await controller.setVisible(false);
      expect(notified, 2);

      await controller.useRoleDefault();
      expect(notified, 3);
    });

    test(
      'an in-memory controller behaves the same and writes nothing',
      () async {
        final controller = MiniMapDisplayController.inMemory(
          explicitChoice: true,
        );
        addTearDown(controller.dispose);

        expect(controller.visibleFor(RideRole.rider), isTrue);
        await controller.useRoleDefault();
        expect(controller.visibleFor(RideRole.rider), isFalse);
        await controller.setVisible(false);
        expect(controller.visibleFor(RideRole.lead), isFalse);

        final preferences = await SharedPreferences.getInstance();
        expect(
          preferences.containsKey(MiniMapDisplayController.preferenceKey),
          false,
        );
      },
    );
  });
}

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/app_update_gate_controller.dart';
import 'package:ride_relay/features/update/update_required_screen.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';

/// The startup update gate (#37): it informs, it fails open, and it never takes
/// back a verdict because the relay went quiet.
void main() {
  group('AppUpdateGateController', () {
    test('starts unknown, and with no relay endpoint stays unknown', () async {
      final controller = AppUpdateGateController(checkCompatibility: null);
      addTearDown(controller.dispose);

      await controller.check();

      expect(controller.state.phase, UpdateGatePhase.unknown);
      expect(controller.updateRequired, isFalse);
    });

    test(
      'a retired build becomes update required, with what the screen needs',
      () async {
        final controller = AppUpdateGateController(
          checkCompatibility: () async => _result(
            RelayCompatibilityDisposition.updateRequired,
            minimumClientBuild: 103,
            clientBuild: 98,
            message: 'Build 98 is older than 103.',
            updateUri: Uri.parse('https://tailendcharlie.app/update'),
          ),
        );
        addTearDown(controller.dispose);
        var notifications = 0;
        controller.addListener(() => notifications += 1);

        await controller.check();

        expect(controller.updateRequired, isTrue);
        expect(controller.state.minimumBuild, 103);
        expect(controller.state.clientBuild, 98);
        expect(controller.state.message, 'Build 98 is older than 103.');
        expect(
          controller.state.relayUpdateUri,
          Uri.parse('https://tailendcharlie.app/update'),
        );
        expect(notifications, 1);
      },
    );

    test('a compatible build, and a legacy relay, are current', () async {
      for (final disposition in [
        RelayCompatibilityDisposition.compatible,
        RelayCompatibilityDisposition.legacyCompatible,
      ]) {
        final controller = AppUpdateGateController(
          checkCompatibility: () async => _result(disposition),
        );
        addTearDown(controller.dispose);

        await controller.check();

        expect(
          controller.state.phase,
          UpdateGatePhase.current,
          reason: '$disposition',
        );
        expect(controller.updateRequired, isFalse);
      }
    });

    test('fails open: no answer is never an update request', () async {
      for (final probe in <Future<RelayCompatibilityResult> Function()>[
        () => throw const InternetRelayException('down', retryable: true),
        () => throw TimeoutException('slow'),
        () => throw StateError('anything at all'),
        () async =>
            _result(RelayCompatibilityDisposition.temporarilyUnavailable),
      ]) {
        final controller = AppUpdateGateController(checkCompatibility: probe);
        addTearDown(controller.dispose);

        await controller.check();

        expect(controller.state.phase, UpdateGatePhase.unknown);
      }
    });

    test('an app newer than the relay is not asked to update', () async {
      final controller = AppUpdateGateController(
        checkCompatibility: () async =>
            _result(RelayCompatibilityDisposition.serverUpgradeRequired),
      );
      addTearDown(controller.dispose);

      await controller.check();

      expect(controller.updateRequired, isFalse);
    });

    test('a verdict is not taken back because a later check failed', () async {
      var answer = 0;
      final controller = AppUpdateGateController(
        checkCompatibility: () async {
          answer += 1;
          if (answer == 1) {
            return _result(RelayCompatibilityDisposition.updateRequired);
          }
          throw const InternetRelayException('offline', retryable: true);
        },
      );
      addTearDown(controller.dispose);

      await controller.check();
      await controller.check();
      await controller.check();

      expect(answer, 3);
      expect(controller.updateRequired, isTrue);
    });

    test('a later definite answer from the relay does replace it', () async {
      var minimumRaised = true;
      final controller = AppUpdateGateController(
        checkCompatibility: () async => _result(
          minimumRaised
              ? RelayCompatibilityDisposition.updateRequired
              : RelayCompatibilityDisposition.compatible,
        ),
      );
      addTearDown(controller.dispose);

      await controller.check();
      expect(controller.updateRequired, isTrue);
      minimumRaised = false;
      await controller.check();

      expect(controller.state.phase, UpdateGatePhase.current);
    });

    test('concurrent checks share one probe', () async {
      var probes = 0;
      final gate = Completer<RelayCompatibilityResult>();
      final controller = AppUpdateGateController(
        checkCompatibility: () {
          probes += 1;
          return gate.future;
        },
      );
      addTearDown(controller.dispose);

      final first = controller.check();
      final second = controller.check();
      gate.complete(_result(RelayCompatibilityDisposition.compatible));
      await Future.wait([first, second]);

      expect(probes, 1);
    });

    test(
      'closes the client it opened and ignores answers after disposal',
      () async {
        var closed = false;
        final gate = Completer<RelayCompatibilityResult>();
        final controller = AppUpdateGateController(
          checkCompatibility: () => gate.future,
          closeProbe: () => closed = true,
        );

        final pending = controller.check();
        controller.dispose();
        gate.complete(_result(RelayCompatibilityDisposition.updateRequired));
        await pending;

        expect(closed, isTrue);
      },
    );

    test('is offered at most once', () {
      final controller = AppUpdateGateController(checkCompatibility: null);
      addTearDown(controller.dispose);

      expect(controller.presented, isFalse);
      controller.markPresented();
      expect(controller.presented, isTrue);
    });
  });

  group('when the full-screen explanation may open', () {
    AppUpdateGateController required() {
      final controller = AppUpdateGateController(checkCompatibility: null)
        ..apply(_result(RelayCompatibilityDisposition.updateRequired));
      addTearDown(controller.dispose);
      return controller;
    }

    test('on the home map, once, when the relay has refused this build', () {
      final gate = required();

      expect(
        shouldOfferUpdateScreen(
          gate: gate,
          hasActiveRide: false,
          restoring: false,
        ),
        isTrue,
      );
      gate.markPresented();
      expect(
        shouldOfferUpdateScreen(
          gate: gate,
          hasActiveRide: false,
          restoring: false,
        ),
        isFalse,
      );
    });

    test('never over a ride in progress, or one being restored', () {
      final gate = required();

      expect(
        shouldOfferUpdateScreen(
          gate: gate,
          hasActiveRide: true,
          restoring: false,
        ),
        isFalse,
      );
      expect(
        shouldOfferUpdateScreen(
          gate: gate,
          hasActiveRide: false,
          restoring: true,
        ),
        isFalse,
      );
    });

    test('never when the relay has not refused this build', () {
      final gate = AppUpdateGateController(checkCompatibility: null)
        ..apply(_result(RelayCompatibilityDisposition.compatible));
      addTearDown(gate.dispose);

      expect(
        shouldOfferUpdateScreen(
          gate: gate,
          hasActiveRide: false,
          restoring: false,
        ),
        isFalse,
      );
    });
  });
}

RelayCompatibilityResult _result(
  RelayCompatibilityDisposition disposition, {
  int? minimumClientBuild,
  int? clientBuild,
  String? message,
  Uri? updateUri,
}) => RelayCompatibilityResult(
  disposition: disposition,
  serverProtocol: 1,
  minimumClientProtocol: 1,
  capabilities: const {},
  checkedAt: DateTime.utc(2026, 10, 9),
  validUntil: DateTime.utc(2026, 10, 9, 0, 5),
  message: message,
  updateUri: updateUri,
  minimumClientBuild: minimumClientBuild,
  clientBuild: clientBuild,
);

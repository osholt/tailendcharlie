import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/ride_invitation_link_controller.dart';
import 'package:ride_relay/services/ride_invitation_link.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cold-start invitation is pulled and validated', () async {
    final source = _QueuedSource([
      rideInvitationUrl('123456', 'Abcdefghijklmnop12345678'),
    ]);
    final controller = await RideInvitationLinkController.load(source: source);

    expect(controller.pending?.rideCode, '123456');
    expect(controller.pending?.joinToken, 'Abcdefghijklmnop12345678');
    expect(controller.errorMessage, isNull);

    controller.dispose();
  });

  test(
    'warm refresh replaces a malformed notice with a later valid link',
    () async {
      final source = _QueuedSource([
        'https://tailendcharlie.app/join.html#bad',
      ]);
      final controller = await RideInvitationLinkController.load(
        source: source,
      );

      expect(controller.pending, isNull);
      expect(controller.errorMessage, contains('malformed'));

      source.values.add(
        rideInvitationUrl('654321', 'ZYXWVUTSRQPONMLK12345678'),
      );
      await controller.refresh();

      expect(controller.pending?.rideCode, '654321');
      expect(controller.errorMessage, isNull);

      controller.dispose();
    },
  );
}

class _QueuedSource implements IncomingRideInvitationLinkSource {
  _QueuedSource(Iterable<String> initial) : values = [...initial];

  final List<String> values;

  @override
  Future<String?> consumePending() async =>
      values.isEmpty ? null : values.removeAt(0);
}

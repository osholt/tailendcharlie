import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/completed_rides_controller.dart';
import 'package:ride_relay/controllers/eta_calibration_controller.dart';
import 'package:ride_relay/domain/completed_ride_store.dart';
import 'package:ride_relay/services/eta_population_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/eta_calibration_test.dart' show calibrationRide;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'opt-in is separate, defaults off; reset replaces shared profile',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = InMemoryCompletedRideStore();
      for (var i = 0; i < 3; i++) {
        await store.save(calibrationRide('$i'));
      }
      final rides = await CompletedRidesController.load(store);
      final client = FakePopulation();
      final controller = await EtaCalibrationController.load(
        rides: rides,
        client: client,
      );
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(controller.sampleCount, 3);
      expect(client.uploads, isEmpty);
      expect(
        controller.factorFor(rides.allRides.first.plannedRoute!),
        lessThan(1),
      );
      await controller.setContributing(true);
      expect(client.uploads.single, {'mixed': .8});
      await controller.refresh();
      expect(
        client.uploads,
        hasLength(1),
        reason: 'checkpoint replay does not re-upload unchanged statistics',
      );
      await controller.reset();
      expect(controller.sampleCount, 0);
      expect(client.uploads.last, isEmpty);
    },
  );
  test(
    'offline opt-out persists and retries deletion without uploading',
    () async {
      SharedPreferences.setMockInitialValues({
        EtaCalibrationController.shareKey: true,
      });
      final rides = await CompletedRidesController.load(
        InMemoryCompletedRideStore(),
      );
      final client = FakePopulation()..offline = true;
      final controller = await EtaCalibrationController.load(
        rides: rides,
        client: client,
      );
      await controller.setContributing(false);
      expect(controller.contributing, isFalse);
      expect(controller.removalPending, isTrue);
      controller.dispose();
      client.offline = false;
      final restarted = await EtaCalibrationController.load(
        rides: rides,
        client: client,
      );
      addTearDown(restarted.dispose);
      await restarted.refresh();
      expect(restarted.removalPending, isFalse);
      expect(client.revocations, 2);
      expect(client.uploads, isEmpty);
    },
  );
}

class FakePopulation extends EtaPopulationClient {
  FakePopulation() : super(baseUri: Uri.parse('https://relay.test/api'));
  bool offline = false;
  int revocations = 0;
  final uploads = <Map<String, double>>[];
  @override
  Future<Map<String, double>> fetch() async => {};
  @override
  Future<void> replace(Map<String, double> bands) async {
    uploads.add(Map.of(bands));
  }

  @override
  Future<void> revoke() async {
    revocations++;
    if (offline) throw StateError('offline');
  }

  @override
  void close() {}
}

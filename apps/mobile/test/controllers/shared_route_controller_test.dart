import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/shared_route_controller.dart';
import 'package:ride_relay/internet/plan_directory.dart';
import 'package:ride_relay/services/gpx_import_source.dart';
import 'package:ride_relay/services/planner_link_channel.dart';
import 'package:ride_relay/services/shared_gpx_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cold-start planner link fetches and stages a GPX route', () async {
    final source = _PlannerLinkSource([
      'https://tailendcharlie.app/planner.html?code=7f3k9qrt',
    ]);
    final directory = _PlanDirectory(
      result: const FetchedPlan(name: 'Sunday / Loop', gpx: '<gpx />'),
    );

    final controller = await SharedRouteController.load(
      channel: const _NoGpxChannel(),
      plannerLinkSource: source,
      planDirectory: directory,
    );
    addTearDown(controller.dispose);

    expect(directory.codes, ['7F3K9QRT']);
    expect(controller.pending?.name, 'Sunday Loop.gpx');
    expect(controller.pending?.bytes, Uint8List.fromList('<gpx />'.codeUnits));
    expect(controller.plannerLinkStatus, PlannerLinkStatus.idle);
  });

  test('warm-resume refresh consumes a newly delivered planner link', () async {
    final source = _PlannerLinkSource([]);
    final directory = _PlanDirectory(
      result: const FetchedPlan(name: 'Evening route', gpx: '<gpx />'),
    );
    final controller = await SharedRouteController.load(
      channel: const _NoGpxChannel(),
      plannerLinkSource: source,
      planDirectory: directory,
    );
    addTearDown(controller.dispose);
    expect(controller.pending, isNull);

    source.values.add('https://tailendcharlie.app/planner.html?code=AB12CD34');
    await controller.refreshForTesting();

    expect(directory.codes, ['AB12CD34']);
    expect(controller.pending?.name, 'Evening route.gpx');
  });

  test(
    'expired code is recoverable through a clear manual-code message',
    () async {
      final controller = await SharedRouteController.load(
        channel: const _NoGpxChannel(),
        plannerLinkSource: _PlannerLinkSource([
          'https://tailendcharlie.app/planner.html?code=EXPIRED1',
        ]),
        planDirectory: _PlanDirectory(
          error: const PlanDirectoryException(
            'That plan code was not found. It may have expired.',
          ),
        ),
      );
      addTearDown(controller.dispose);

      expect(controller.pending, isNull);
      expect(controller.plannerLinkStatus, PlannerLinkStatus.error);
      expect(controller.plannerLinkCode, 'EXPIRED1');
      expect(controller.plannerLinkMessage, contains('expired'));
      expect(controller.canRetryPlannerLink, isFalse);

      controller.clearPlannerLinkNotice();
      expect(controller.plannerLinkStatus, PlannerLinkStatus.idle);
    },
  );

  test('retryable link failure can fetch the same code again', () async {
    final directory = _PlanDirectory(
      error: const PlanDirectoryException(
        'Plan service timed out.',
        retryable: true,
      ),
    );
    final controller = await SharedRouteController.load(
      channel: const _NoGpxChannel(),
      plannerLinkSource: _PlannerLinkSource([
        'https://tailendcharlie.app/planner.html?code=AB12CD34',
      ]),
      planDirectory: directory,
    );
    addTearDown(controller.dispose);
    expect(controller.canRetryPlannerLink, isTrue);

    directory
      ..error = null
      ..result = const FetchedPlan(name: 'Recovered', gpx: '<gpx />');
    await controller.retryPlannerLink();

    expect(directory.codes, ['AB12CD34', 'AB12CD34']);
    expect(controller.pending?.name, 'Recovered.gpx');
    expect(controller.plannerLinkStatus, PlannerLinkStatus.idle);
  });
}

class _PlannerLinkSource implements IncomingPlannerLinkSource {
  _PlannerLinkSource(this.values);

  final List<String> values;

  @override
  Future<String?> consumePending() async =>
      values.isEmpty ? null : values.removeAt(0);
}

class _PlanDirectory implements PlanDirectory {
  _PlanDirectory({this.result, this.error});

  FetchedPlan? result;
  PlanDirectoryException? error;
  final codes = <String>[];

  @override
  Future<FetchedPlan> fetch(String code) async {
    codes.add(code);
    final failure = error;
    if (failure != null) throw failure;
    return result!;
  }
}

class _NoGpxChannel extends SharedGpxChannel {
  const _NoGpxChannel();

  @override
  Future<PickedGpxFile?> consumePending() async => null;
}

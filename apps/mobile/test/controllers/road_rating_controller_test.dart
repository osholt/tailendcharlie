// Asking, storing and releasing anonymous road ratings (#159).
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/road_rating_controller.dart';
import 'package:ride_relay/domain/imported_route.dart' show GeoPoint;
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/internet/road_rating_client.dart';
import 'package:ride_relay/services/motorcycle_discovery.dart';
import 'package:ride_relay/services/road_rating.dart';
import 'package:ride_relay/services/road_rating_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _catalogueVersion = 'uk-osm-2026-07-23-v1';
final _now = DateTime.utc(2026, 7, 28, 18);

List<GeoPoint> _line({double latitude = 52, int count = 40}) => [
  for (var index = 0; index < count; index += 1)
    GeoPoint(latitude: latitude, longitude: -3 + index * 0.0015),
];

MotorcycleDiscoveryCatalogue _catalogue({int roads = 1}) =>
    MotorcycleDiscoveryCatalogue([
      for (var index = 0; index < roads; index += 1)
        MotorcycleDiscoveryFeature(
          id: 'road-$index',
          category: MotorcycleDiscoveryCategory.goodBikingRoad,
          name: 'Road $index',
          points: _line(latitude: 52 + index * 0.0000005),
          sourceName: 'OpenStreetMap via Geofabrik',
          sourceUrl: 'https://www.openstreetmap.org/way/1',
          confidence: 'medium',
          lastVerified: '2026-07-24',
          warning: 'Descriptive discovery hint only.',
          score: 99 - index,
          sourceFeatureId: 'derived/road-$index',
        ),
    ], version: _catalogueVersion);

class _RecordingRatingApi implements RoadRatingApi {
  _RecordingRatingApi({this.failure});

  final InternetRelayException? failure;
  final submitted = <Map<String, Object?>>[];
  var closed = false;

  @override
  Future<void> submit(RoadRating rating) async {
    if (failure case final error?) throw error;
    submitted.add(rating.toRequestJson());
  }

  @override
  void close() => closed = true;
}

class _FakeCompatibility implements RelayCompatibilityApi {
  _FakeCompatibility({this.capabilities = RelayProtocolCapabilities.current});

  final Set<String> capabilities;
  var checks = 0;

  @override
  Future<RelayCompatibilityResult> checkCompatibility() async {
    checks += 1;
    return RelayCompatibilityResult(
      disposition: RelayCompatibilityDisposition.compatible,
      serverProtocol: 1,
      minimumClientProtocol: 1,
      capabilities: capabilities,
      checkedAt: _now,
      validUntil: _now.add(const Duration(minutes: 5)),
    );
  }
}

Future<RoadRatingController> _controller({
  int roads = 1,
  RoadRatingApi? client,
  RelayCompatibilityApi? compatibility,
  Duration minimumReleaseDelay =
      RoadRatingController.defaultMinimumReleaseDelay,
  Duration maximumReleaseDelay =
      RoadRatingController.defaultMaximumReleaseDelay,
  DateTime Function()? clock,
}) async => RoadRatingController(
  store: await RoadRatingStore.openDefault(),
  loadCatalogue: () async => _catalogue(roads: roads),
  client: client,
  compatibility: compatibility,
  clock: clock ?? () => _now,
  random: Random(7),
  minimumReleaseDelay: minimumReleaseDelay,
  maximumReleaseDelay: maximumReleaseDelay,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a ride crossing no catalogued road asks nothing', () async {
    final controller = await _controller();
    addTearDown(controller.dispose);

    await controller.prepare(riddenTrack: const []);

    expect(controller.hasQuestions, isFalse);
    expect(controller.questions, isEmpty);
  });

  test('a ride crossing one road asks about exactly that road', () async {
    final controller = await _controller();
    addTearDown(controller.dispose);

    await controller.prepare(riddenTrack: _line());

    expect(controller.questions.map((road) => road.feature.id), ['road-0']);
    expect(controller.current!.feature.name, 'Road 0');
  });

  test('a ride crossing many roads is capped at three', () async {
    final controller = await _controller(roads: 8);
    addTearDown(controller.dispose);

    await controller.prepare(riddenTrack: _line());

    expect(controller.questions, hasLength(3));
  });

  test('what is sent carries no rider, device, ride or timestamp', () async {
    final client = _RecordingRatingApi();
    final controller = await _controller(
      client: client,
      compatibility: _FakeCompatibility(),
      minimumReleaseDelay: Duration.zero,
      maximumReleaseDelay: Duration.zero,
    );
    addTearDown(controller.dispose);
    await controller.prepare(riddenTrack: _line());

    await controller.answer(RoadRatingVerdict.worthIncluding);
    await controller.flushPending();

    expect(client.submitted, hasLength(1));
    expect(client.submitted.single, {
      'featureId': 'road-0',
      'sourceFeatureId': 'derived/road-0',
      'category': 'good_biking_road',
      'verdict': 'worth_including',
      'catalogueVersion': _catalogueVersion,
    });
  });

  test('an answer is held back, not sent at the end of the ride', () async {
    final client = _RecordingRatingApi();
    final controller = await _controller(
      client: client,
      compatibility: _FakeCompatibility(),
    );
    addTearDown(controller.dispose);
    await controller.prepare(riddenTrack: _line());

    await controller.answer(RoadRatingVerdict.worthIncluding);
    await controller.flushPending();

    expect(client.submitted, isEmpty);
    expect(controller.pendingCount, 1);

    // Once the randomised delay has elapsed it goes out on its own.
    final later = await _controller(
      client: client,
      compatibility: _FakeCompatibility(),
      clock: () => _now.add(const Duration(days: 2)),
    );
    addTearDown(later.dispose);
    await later.flushPending();

    expect(client.submitted, hasLength(1));
    expect(later.pendingCount, 0);
  });

  test('each answer draws its own release time inside the window', () async {
    final controller = await _controller(roads: 3);
    addTearDown(controller.dispose);
    await controller.prepare(riddenTrack: _line());

    await controller.answer(RoadRatingVerdict.worthIncluding);
    await controller.answer(RoadRatingVerdict.notWorthIncluding);
    await controller.answer(RoadRatingVerdict.worthIncluding);

    final store = await RoadRatingStore.openDefault();
    final releases = store.pending
        .map((rating) => rating.releaseAfter)
        .toList();
    expect(releases, hasLength(3));
    expect(releases.toSet(), hasLength(3));
    for (final release in releases) {
      expect(
        release.isAfter(
          _now
              .add(RoadRatingController.defaultMinimumReleaseDelay)
              .subtract(const Duration(seconds: 1)),
        ),
        isTrue,
      );
      expect(
        release.isBefore(
          _now
              .add(RoadRatingController.defaultMaximumReleaseDelay)
              .add(const Duration(seconds: 1)),
        ),
        isTrue,
      );
    }
  });

  test('skipping a road sends nothing and does not ask again', () async {
    final controller = await _controller(roads: 2);
    addTearDown(controller.dispose);
    await controller.prepare(riddenTrack: _line());

    await controller.skip();

    expect(controller.pendingCount, 0);
    expect(controller.current!.feature.id, 'road-1');

    final store = await RoadRatingStore.openDefault();
    expect(store.askedFeatureIds(now: _now), {'road-0'});
  });

  test('not now puts the whole card away without marking anything', () async {
    final controller = await _controller(roads: 3);
    addTearDown(controller.dispose);
    await controller.prepare(riddenTrack: _line());

    controller.dismiss();

    expect(controller.hasQuestions, isFalse);
    final store = await RoadRatingStore.openDefault();
    expect(store.askedFeatureIds(now: _now), isEmpty);
  });

  test('answering every road finishes the card', () async {
    final controller = await _controller(roads: 2);
    addTearDown(controller.dispose);
    await controller.prepare(riddenTrack: _line());

    await controller.answer(RoadRatingVerdict.worthIncluding);
    await controller.answer(RoadRatingVerdict.notWorthIncluding);

    expect(controller.finished, isTrue);
    expect(controller.current, isNull);
    expect(controller.answeredCount, 2);
  });

  test(
    'a relay without the capability keeps the answer and names the limitation',
    () async {
      final client = _RecordingRatingApi();
      final controller = await _controller(
        client: client,
        compatibility: _FakeCompatibility(
          capabilities: RelayProtocolCapabilities.current
              .where(
                (capability) =>
                    capability != RelayProtocolCapabilities.roadRatings,
              )
              .toSet(),
        ),
        minimumReleaseDelay: Duration.zero,
        maximumReleaseDelay: Duration.zero,
      );
      addTearDown(controller.dispose);
      await controller.prepare(riddenTrack: _line());

      await controller.answer(RoadRatingVerdict.worthIncluding);
      await controller.flushPending();

      expect(client.submitted, isEmpty);
      expect(controller.pendingCount, 1);
      expect(
        controller.limitation,
        RoadRatingLimitation.serviceCapabilityMissing,
      );
    },
  );

  test('a relay that predates the endpoint keeps the answer', () async {
    final client = _RecordingRatingApi(
      failure: const InternetRelayException(
        'Road rating was not accepted (HTTP 404).',
        statusCode: 404,
      ),
    );
    final controller = await _controller(
      client: client,
      compatibility: _FakeCompatibility(),
      minimumReleaseDelay: Duration.zero,
      maximumReleaseDelay: Duration.zero,
    );
    addTearDown(controller.dispose);
    await controller.prepare(riddenTrack: _line());

    await controller.answer(RoadRatingVerdict.worthIncluding);
    await controller.flushPending();

    expect(controller.pendingCount, 1);
    expect(
      controller.limitation,
      RoadRatingLimitation.serviceCapabilityMissing,
    );
  });

  test(
    'an offline answer stays queued and is sent on the next flush',
    () async {
      final failing = _RecordingRatingApi(
        failure: const InternetRelayException(
          'Road ratings are temporarily unavailable.',
          retryable: true,
        ),
      );
      final offline = await _controller(
        client: failing,
        compatibility: _FakeCompatibility(),
        minimumReleaseDelay: Duration.zero,
        maximumReleaseDelay: Duration.zero,
      );
      addTearDown(offline.dispose);
      await offline.prepare(riddenTrack: _line());

      await offline.answer(RoadRatingVerdict.worthIncluding);
      await offline.flushPending();

      expect(offline.pendingCount, 1);
      expect(offline.limitation, RoadRatingLimitation.serviceUnreachable);

      // Same durable storage, a working relay: the answer survived.
      final working = _RecordingRatingApi();
      final online = await _controller(
        client: working,
        compatibility: _FakeCompatibility(),
      );
      addTearDown(online.dispose);
      await online.flushPending();

      expect(working.submitted.single['featureId'], 'road-0');
      expect(online.pendingCount, 0);
      expect(online.limitation, RoadRatingLimitation.none);
    },
  );

  test(
    'a build with no catalogue service says so instead of pretending',
    () async {
      final controller = await _controller(
        minimumReleaseDelay: Duration.zero,
        maximumReleaseDelay: Duration.zero,
      );
      addTearDown(controller.dispose);
      await controller.prepare(riddenTrack: _line());

      await controller.answer(RoadRatingVerdict.worthIncluding);
      await controller.flushPending();

      expect(controller.pendingCount, 1);
      expect(controller.limitation, RoadRatingLimitation.serviceNotConfigured);
    },
  );

  test('a queued rating is not held in ride storage', () async {
    final controller = await _controller();
    addTearDown(controller.dispose);
    await controller.prepare(riddenTrack: _line());
    await controller.answer(RoadRatingVerdict.worthIncluding);

    final preferences = await SharedPreferences.getInstance();
    final raw = preferences.getString(RoadRatingStore.pendingKey)!;
    final stored = (jsonDecode(raw) as List).single as Map<String, Object?>;

    // The whole of what the phone keeps: no ride ID, no rider ID, no device ID.
    expect(stored.keys.toSet(), {
      'featureId',
      'sourceFeatureId',
      'category',
      'verdict',
      'catalogueVersion',
      'releaseAfter',
    });
  });

  test('preparing twice does not ask twice', () async {
    final controller = await _controller(roads: 2);
    addTearDown(controller.dispose);

    await controller.prepare(riddenTrack: _line());
    await controller.answer(RoadRatingVerdict.worthIncluding);
    await controller.prepare(riddenTrack: _line());

    expect(controller.answeredCount, 1);
    expect(controller.questions, hasLength(2));
  });

  test('a catalogue that will not load produces no card', () async {
    final controller = RoadRatingController(
      store: await RoadRatingStore.openDefault(),
      loadCatalogue: () async =>
          throw const FormatException('Discovery catalogue must be GeoJSON.'),
      clock: () => _now,
    );
    addTearDown(controller.dispose);

    await controller.prepare(riddenTrack: _line());

    expect(controller.hasQuestions, isFalse);
  });

  test('an unconfigured build builds no controller at all', () async {
    expect(
      await RoadRatingController.openDefault(
        configuration: const RoadRatingConfiguration(null),
      ),
      isNull,
    );
  });

  test('an empty queue needs no relay round trip to flush', () async {
    final compatibility = _FakeCompatibility();
    final controller = await _controller(
      client: _RecordingRatingApi(),
      compatibility: compatibility,
    );
    addTearDown(controller.dispose);

    await controller.flushPending();

    // The launch-time drain must cost nothing when there is nothing to send.
    expect(compatibility.checks, 0);
    expect(controller.limitation, RoadRatingLimitation.none);
  });
}

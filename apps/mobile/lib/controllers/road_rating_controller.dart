import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../domain/imported_route.dart' show GeoPoint;
import '../internet/internet_relay_client.dart';
import '../internet/road_rating_client.dart';
import '../services/motorcycle_discovery.dart';
import '../services/ridden_road_matcher.dart';
import '../services/road_rating.dart';
import '../services/road_rating_store.dart';

/// Why a rating has not left the phone yet. Named, because "thanks, sent" when
/// nothing was sent is the failure this whole capability check exists to avoid.
enum RoadRatingLimitation {
  none,

  /// This build has no discovery endpoint compiled in, so nothing can be sent.
  serviceNotConfigured,

  /// The relay does not advertise `road-ratings-v1`. The answers stay queued;
  /// a relay deploy is what unblocks them.
  serviceCapabilityMissing,

  /// The relay is reachable in principle but the submission failed. Retried on
  /// the next flush.
  serviceUnreachable,
}

/// Drives the end-of-ride road-rating card (#159).
///
/// Owns the whole of the "ask, store, release later" cycle. Nothing here is
/// keyed by ride, and nothing runs while riding: [prepare] is called once, after
/// the ride has ended, from the ended-ride screen.
class RoadRatingController extends ChangeNotifier {
  factory RoadRatingController({
    required RoadRatingStore store,
    required Future<MotorcycleDiscoveryCatalogue> Function() loadCatalogue,
    RoadRatingApi? client,
    RelayCompatibilityApi? compatibility,
    RiddenRoadMatcher matcher = const RiddenRoadMatcher(),
    DateTime Function() clock = DateTime.now,
    Random? random,
    Duration minimumReleaseDelay = defaultMinimumReleaseDelay,
    Duration maximumReleaseDelay = defaultMaximumReleaseDelay,
  }) => RoadRatingController._(
    store,
    loadCatalogue,
    client,
    compatibility,
    matcher,
    clock,
    random ?? Random.secure(),
    minimumReleaseDelay,
    maximumReleaseDelay,
  );

  RoadRatingController._(
    this._store,
    this._loadCatalogue,
    this._client,
    this._compatibility,
    this._matcher,
    this._clock,
    this._random,
    this.minimumReleaseDelay,
    this.maximumReleaseDelay,
  );

  /// Builds the production controller. Returns null when this build has no
  /// discovery endpoint, so the card never appears in a build that could not
  /// deliver an answer.
  static Future<RoadRatingController?> openDefault({
    RoadRatingConfiguration? configuration,
  }) async {
    final resolved = configuration ?? RoadRatingConfiguration.fromEnvironment();
    if (!resolved.isConfigured) return null;
    final controller = RoadRatingController(
      store: await RoadRatingStore.openDefault(),
      loadCatalogue: MotorcycleDiscoveryCatalogue.loadAsset,
      client: HttpRoadRatingClient(
        configuration: resolved,
        client: http.Client(),
      ),
      compatibility: HttpInternetRelayClient(
        configuration: resolved.compatibilityConfiguration,
        client: http.Client(),
      ),
    );
    // Every app launch drains whatever is due. Otherwise the only trigger would
    // be the end of the next ride, and a rating given after somebody's last ride
    // of the season would sit on the phone until they rode again. Unawaited and
    // a no-op on an empty queue, so it costs a launch nothing.
    unawaited(controller.flushPending());
    return controller;
  }

  /// The shortest a rating waits before it is sent.
  ///
  /// Not zero, and not "when the screen closes". The relay sees the source IP of
  /// both the ride's own sync traffic and a rating; a rating that arrives while
  /// the ride is still syncing could be lined up against it by anyone holding
  /// the relay's logs. Half an hour is already past the end of a ride's event
  /// retention for positions.
  static const defaultMinimumReleaseDelay = Duration(minutes: 30);

  /// The longest. Each rating draws its own delay independently and uniformly
  /// in this window, so three answers from one rider do not arrive as a
  /// recognisable burst either.
  static const defaultMaximumReleaseDelay = Duration(hours: 18);

  final RoadRatingStore _store;
  final Future<MotorcycleDiscoveryCatalogue> Function() _loadCatalogue;
  final RoadRatingApi? _client;
  final RelayCompatibilityApi? _compatibility;
  final RiddenRoadMatcher _matcher;
  final DateTime Function() _clock;
  final Random _random;
  final Duration minimumReleaseDelay;
  final Duration maximumReleaseDelay;

  List<RiddenRoad> _questions = const [];
  int _index = 0;
  bool _prepared = false;
  bool _dismissed = false;
  String _catalogueVersion = MotorcycleDiscoveryCatalogue.unknownVersion;
  RoadRatingLimitation _limitation = RoadRatingLimitation.none;

  /// The roads to ask about, at most three, best first.
  List<RiddenRoad> get questions => _questions;

  /// True once [prepare] has run, whether or not it found anything.
  bool get prepared => _prepared;

  /// A ride that crossed no catalogued road never asks anything.
  bool get hasQuestions => _questions.isNotEmpty && !_dismissed;

  RiddenRoad? get current =>
      _index < _questions.length ? _questions[_index] : null;

  int get answeredCount => _index;

  bool get finished => _questions.isNotEmpty && _index >= _questions.length;

  bool get dismissed => _dismissed;

  RoadRatingLimitation get limitation => _limitation;

  /// How many answers are still on the phone waiting to go out.
  int get pendingCount => _store.pending.length;

  /// Works out what to ask, then drains anything already due from earlier rides.
  ///
  /// Idempotent: the ended-ride screen rebuilds freely, and a second call is a
  /// no-op rather than a second set of questions.
  Future<void> prepare({required List<GeoPoint> riddenTrack}) async {
    if (_prepared) return;
    _prepared = true;
    try {
      final catalogue = await _loadCatalogue();
      _catalogueVersion = catalogue.version;
      _questions = _matcher.match(
        catalogue: catalogue,
        riddenTrack: riddenTrack,
        excludedFeatureIds: _store.askedFeatureIds(now: _clock()),
      );
    } on Object catch (error) {
      // A catalogue that will not load is not worth interrupting the end of a
      // ride for. No questions, no card.
      debugPrint('Could not prepare road ratings: $error');
      _questions = const [];
    }
    notifyListeners();
    await flushPending();
  }

  /// Records the rider's verdict for [current] and moves on.
  Future<void> answer(RoadRatingVerdict verdict) async {
    final question = current;
    if (question == null) return;
    final now = _clock();
    await _store.record(
      RoadRating(
        featureId: question.feature.id,
        sourceFeatureId: question.feature.sourceFeatureId,
        category: question.feature.category,
        verdict: verdict,
        catalogueVersion: _catalogueVersion,
        releaseAfter: now.add(_releaseDelay()),
      ),
      now: now,
    );
    _index += 1;
    notifyListeners();
  }

  /// Skips [current] without sending anything, and does not ask again. Declining
  /// is an answer to the app even though it is not one to the catalogue.
  Future<void> skip() async {
    final question = current;
    if (question == null) return;
    await _store.markAsked(question.feature.id, now: _clock());
    _index += 1;
    notifyListeners();
  }

  /// Puts the whole card away for this ride without marking anything.
  void dismiss() {
    if (_dismissed) return;
    _dismissed = true;
    notifyListeners();
  }

  /// Sends every queued rating whose release time has passed, one request each.
  ///
  /// One rating per request on purpose. Batching three answers would tell the
  /// relay that those three roads were rated by the same person in the same
  /// sitting, which - against a ride whose positions the relay also carried - is
  /// most of the way back to identifying the rider.
  Future<void> flushPending() async {
    final client = _client;
    if (client == null) {
      _setLimitation(RoadRatingLimitation.serviceNotConfigured);
      return;
    }
    if (_store.pending.isEmpty) {
      _setLimitation(RoadRatingLimitation.none);
      return;
    }
    final compatibility = _compatibility;
    if (compatibility != null) {
      try {
        final result = await compatibility.checkCompatibility();
        if (!result.canSynchronize ||
            !result.supports(RelayProtocolCapabilities.roadRatings)) {
          _setLimitation(RoadRatingLimitation.serviceCapabilityMissing);
          return;
        }
      } on Object {
        _setLimitation(RoadRatingLimitation.serviceUnreachable);
        return;
      }
    }

    final now = _clock();
    var limitation = RoadRatingLimitation.none;
    // Randomised order, so the queue's own insertion order does not reveal which
    // roads were rated first.
    final due =
        _store.pending
            .where((rating) => !rating.releaseAfter.isAfter(now.toUtc()))
            .toList()
          ..shuffle(_random);
    for (final rating in due) {
      try {
        await client.submit(rating);
        await _store.remove(rating);
      } on InternetRelayException catch (error) {
        if (error.statusCode == 404) {
          // The relay predates the endpoint. Keep the answer and say so.
          limitation = RoadRatingLimitation.serviceCapabilityMissing;
          break;
        }
        if (error.retryable) {
          limitation = RoadRatingLimitation.serviceUnreachable;
          break;
        }
        // A body this relay will never accept. Dropping it is the only way out
        // of an otherwise permanent queue, and it is logged rather than silent.
        debugPrint('Dropping unacceptable road rating: ${error.message}');
        await _store.remove(rating);
      } on Object catch (error) {
        debugPrint('Could not send road rating: $error');
        limitation = RoadRatingLimitation.serviceUnreachable;
        break;
      }
    }
    _setLimitation(limitation);
  }

  Duration _releaseDelay() {
    final span = maximumReleaseDelay.inSeconds - minimumReleaseDelay.inSeconds;
    if (span <= 0) return minimumReleaseDelay;
    return minimumReleaseDelay + Duration(seconds: _random.nextInt(span + 1));
  }

  void _setLimitation(RoadRatingLimitation value) {
    if (_limitation == value) return;
    _limitation = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }
}

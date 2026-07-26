import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/controllers/pre_start_presence_controller.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/relay/live_presence.dart';
import 'package:ride_relay/relay/relay_presence.dart';

/// Two simulated devices sharing one relay, exercising the sequences from the
/// field report in issue #99: a joiner who could see the route but never the
/// leader's advancing position, and a leader who never saw the joiner join.
void main() {
  late _FakeRelay relay;
  late DateTime now;

  DateTime clock() => now;

  setUp(() {
    now = DateTime.utc(2026, 7, 25, 9);
    relay = _FakeRelay(clock);
  });

  _Device device(
    String riderId,
    String name, {
    RideRole role = RideRole.rider,
  }) {
    final session = _session(riderId, name, role);
    final controller = PreStartPresenceController(
      relay.apiFor(riderId),
      pollInterval: const Duration(days: 1),
      clock: clock,
    );
    addTearDown(controller.close);
    return _Device(session, controller, clock);
  }

  test('a rider visible before the start stays visible across it', () async {
    final leader = device('leader', 'Lead', role: RideRole.lead);
    final follower = device('follower', 'Alex');
    relay.join('leader', 'Lead', 'lead');
    relay.join('follower', 'Alex', 'rider');
    await leader.start();
    await follower.start();

    await leader.publish(51.0);
    await follower.publish(51.3);
    expect(follower.visibleRiderIds, containsAll(['leader', 'follower']));
    expect(follower.controller.phase, RidePresencePhase.open);

    relay.startRide();
    now = now.add(const Duration(seconds: 4));
    await leader.publish(51.001);
    await follower.synchronize();

    // No gap and no duplicate identity across `rideStarted`.
    expect(follower.controller.phase, RidePresencePhase.started);
    expect(follower.visibleRiderIds, containsAll(['leader', 'follower']));
    expect(follower.positionFor('leader')!.sample.position.latitude, 51.001);
    expect(
      follower.presence.where((entry) => entry.riderId == 'leader').length,
      1,
    );
  });

  test('the leader sees a rider who joins an already-started ride', () async {
    final leader = device('leader', 'Lead', role: RideRole.lead);
    relay.join('leader', 'Lead', 'lead');
    await leader.start();
    relay.startRide();
    await leader.publish(51.0);

    // The joiner arrives after the start and publishes one fix.
    final joiner = device('joiner', 'Bill');
    relay.join('joiner', 'Bill', 'rider');
    await joiner.start();
    await joiner.publish(51.4);

    // The leader polls presence only: no journal batch is involved.
    now = now.add(const Duration(seconds: 4));
    await leader.synchronize();

    expect(leader.rosterIds, containsAll(['leader', 'joiner']));
    expect(leader.visibleRiderIds, contains('joiner'));
    expect(leader.positionFor('joiner')!.displayName, 'Bill');
    expect(leader.freshnessFor('joiner'), PresenceFreshness.live);
  });

  test(
    'the joiner sees the leader advancing, not one frozen position',
    () async {
      final leader = device('leader', 'Lead', role: RideRole.lead);
      relay.join('leader', 'Lead', 'lead');
      await leader.start();
      relay.startRide();
      final joiner = device('joiner', 'Bill');
      relay.join('joiner', 'Bill', 'rider');
      await joiner.start();

      final observed = <double>[];
      for (var step = 0; step < 4; step += 1) {
        now = now.add(const Duration(seconds: 4));
        await leader.publish(51.0 + step * 0.001);
        await joiner.synchronize();
        observed.add(joiner.positionFor('leader')!.sample.position.latitude);
        expect(joiner.freshnessFor('leader'), PresenceFreshness.live);
      }

      expect(observed, [51.0, 51.001, 51.002, 51.003]);
    },
  );

  test('a rider who restarts the app rejoins without re-opting in', () async {
    final leader = device('leader', 'Lead', role: RideRole.lead);
    relay.join('leader', 'Lead', 'lead');
    relay.join('follower', 'Alex', 'rider');
    await leader.start();
    relay.startRide();

    final first = device('follower', 'Alex');
    await first.start();
    await first.publish(51.2);
    now = now.add(const Duration(seconds: 2));
    await leader.synchronize();
    expect(leader.visibleRiderIds, contains('follower'));

    // A process restart drops every in-memory snapshot on that device.
    await first.controller.stop(clearRemote: false);
    final second = device('follower', 'Alex');
    await second.start();

    expect(second.rosterIds, containsAll(['leader', 'follower']));
    await second.publish(51.21);
    now = now.add(const Duration(seconds: 2));
    await leader.synchronize();
    expect(leader.positionFor('follower')!.sample.position.latitude, 51.21);
  });

  test('presence resumes by itself after a network loss', () async {
    final leader = device('leader', 'Lead', role: RideRole.lead);
    final follower = device('follower', 'Alex');
    relay.join('leader', 'Lead', 'lead');
    relay.join('follower', 'Alex', 'rider');
    await leader.start();
    await follower.start();
    relay.startRide();
    await leader.publish(51.0);
    await follower.synchronize();
    expect(follower.visibleRiderIds, contains('leader'));

    relay.offline = true;
    now = now.add(const Duration(seconds: 4));
    await follower.synchronize();
    expect(
      follower.controller.availability,
      PresenceAvailability.serviceUnreachable,
    );
    expect(
      follower.controller.unavailableReason,
      contains('cannot be reached'),
    );
    // A dropped connection must not blank the last known positions.
    expect(follower.visibleRiderIds, contains('leader'));

    relay.offline = false;
    now = now.add(const Duration(seconds: 4));
    await leader.publish(51.005);
    await follower.synchronize();

    expect(follower.controller.availability, PresenceAvailability.live);
    expect(follower.positionFor('leader')!.sample.position.latitude, 51.005);
    expect(follower.controller.unavailableReason, isNull);
    expect(follower.controller.limitations, isEmpty);
  });

  test(
    'a position that stops updating ages, goes stale, then disappears',
    () async {
      final leader = device('leader', 'Lead', role: RideRole.lead);
      final follower = device('follower', 'Alex');
      relay.join('leader', 'Lead', 'lead');
      await leader.start();
      await follower.start();
      await leader.publish(51.0);
      await follower.synchronize();
      expect(follower.freshnessFor('leader'), PresenceFreshness.live);

      // The leader stops reporting. The relay's own TTL removes the row, but the
      // follower keeps demoting what it last saw rather than blinking it out.
      now = now.add(const Duration(seconds: 30));
      await follower.synchronize();
      expect(follower.freshnessFor('leader'), PresenceFreshness.ageing);

      now = now.add(const Duration(seconds: 45));
      await follower.synchronize();
      expect(follower.freshnessFor('leader'), PresenceFreshness.stale);
      expect(follower.positionFor('leader'), isNotNull);

      // Past the ephemeral channel's retention window the cached snapshot is
      // released. The rider is still named by the roster, now with an explicit
      // "no position" rather than a marker frozen at an old coordinate.
      now = now.add(const Duration(minutes: 6));
      await follower.synchronize();
      expect(follower.freshnessFor('leader'), PresenceFreshness.none);
      expect(follower.positionFor('leader'), isNull);
      expect(follower.rosterIds, contains('leader'));
    },
  );

  test(
    'nearby presence covers a rider the internet relay cannot see',
    () async {
      final follower = device('follower', 'Alex');
      final nearby = _FakeNearbyGateway();
      addTearDown(nearby.close);
      await follower.start();
      await follower.controller.attachNearby(nearby);

      nearby.emit(
        RelayPresenceUpdate(
          riderId: 'peer',
          sentAt: now,
          expiresAt: now.add(const Duration(seconds: 45)),
          clear: false,
          position: _location('peer', 'Sam', 51.9, now),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(follower.visibleRiderIds, contains('peer'));
      expect(
        follower.presence
            .firstWhere((entry) => entry.riderId == 'peer')
            .sources,
        {LivePresenceSource.nearbyPresence},
      );
      expect(follower.controller.nearbyLocations.single.riderId, 'peer');
      expect(follower.controller.internetLocations, isEmpty);
    },
  );

  test('an out-of-order relay reply cannot rewind a rider', () async {
    final follower = device('follower', 'Alex');
    await follower.start();
    relay.publish('leader', 'Lead', 52.0, now);
    await follower.synchronize();
    expect(follower.positionFor('leader')!.sample.position.latitude, 52.0);

    // A delayed reply carrying an older sample for the same rider.
    relay.publish(
      'leader',
      'Lead',
      51.0,
      now.subtract(const Duration(seconds: 30)),
    );
    await follower.synchronize();

    expect(follower.positionFor('leader')!.sample.position.latitude, 52.0);
  });

  test('a service without the capability produces a named state', () async {
    relay.capabilities = const {'ride-start-v1'};
    final follower = device('follower', 'Alex');

    await follower.start();

    expect(
      follower.controller.availability,
      PresenceAvailability.serviceUnsupported,
    );
    expect(follower.controller.supported, isFalse);
    expect(
      follower.controller.limitations.single.kind,
      PresenceLimitationKind.serviceCapabilityMissing,
    );
    expect(follower.controller.unavailableReason, contains('does not support'));
  });

  test(
    'nearby presence still works when the relay lacks the capability',
    () async {
      relay.capabilities = const {'ride-start-v1'};
      final follower = device('follower', 'Alex');
      final nearby = _FakeNearbyGateway();
      addTearDown(nearby.close);
      await follower.start();
      await follower.controller.attachNearby(nearby);

      expect(follower.controller.supported, isTrue);
      nearby.emit(
        RelayPresenceUpdate(
          riderId: 'peer',
          sentAt: now,
          expiresAt: now.add(const Duration(seconds: 45)),
          clear: false,
          position: _location('peer', 'Sam', 51.9, now),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(follower.visibleRiderIds, contains('peer'));
    },
  );

  test('a legacy peer is named rather than silently missing', () async {
    final follower = device('follower', 'Alex');
    relay.join('bill', 'Bill', 'rider');
    relay.publish('bill', 'Bill', 51.7, now, livePresence: false);

    await follower.start();

    final limitation = follower.controller.limitations.single;
    expect(limitation.kind, PresenceLimitationKind.peerAppOlder);
    expect(limitation.riderId, 'bill');
    expect(limitation.message, contains('Bill'));
    // The peer is still shown while their build can publish.
    expect(follower.visibleRiderIds, contains('bill'));
  });

  test(
    'an older relay without a phase field still carries positions',
    () async {
      relay.capabilities = const {'pre-start-presence-v1'};
      relay.reportPhase = false;
      relay.reportMembers = false;
      final follower = device('follower', 'Alex');
      relay.publish('leader', 'Lead', 51.0, now);

      await follower.start();

      expect(follower.controller.availability, PresenceAvailability.live);
      expect(follower.controller.phase, RidePresencePhase.unknown);
      expect(follower.controller.roster, isEmpty);
      expect(follower.visibleRiderIds, contains('leader'));
    },
  );

  test('a rejected ride credential is reported as unauthorized', () async {
    relay.unauthorized = true;
    final follower = device('follower', 'Alex');

    await follower.start();

    expect(
      follower.controller.availability,
      PresenceAvailability.serviceUnauthorized,
    );
    expect(follower.controller.unavailableReason, contains('rejected'));
  });

  test(
    'stopping clears this device from the relay and its peer demotes it',
    () async {
      final leader = device('leader', 'Lead', role: RideRole.lead);
      final follower = device('follower', 'Alex');
      await leader.start();
      await follower.start();
      await leader.publish(51.0);
      await follower.synchronize();
      expect(follower.visibleRiderIds, contains('leader'));

      await leader.controller.stop();
      expect(leader.controller.availability, PresenceAvailability.stopped);
      expect(leader.controller.locations, isEmpty);

      // The peer keeps the last position and demotes it. A marker that silently
      // vanishes is indistinguishable from one that was never there.
      now = now.add(const Duration(seconds: 90));
      await follower.synchronize();
      expect(follower.freshnessFor('leader'), PresenceFreshness.stale);

      now = now.add(const Duration(minutes: 6));
      await follower.synchronize();
      expect(follower.visibleRiderIds, isNot(contains('leader')));
    },
  );

  test('an explicit departure removes a rider immediately', () async {
    final leader = device('leader', 'Lead', role: RideRole.lead);
    final follower = device('follower', 'Alex');
    relay.join('leader', 'Lead', 'lead');
    relay.join('follower', 'Alex', 'rider');
    await leader.start();
    await follower.start();
    await leader.publish(51.0);
    await follower.synchronize();
    expect(follower.visibleRiderIds, contains('leader'));

    relay.leave('leader');
    now = now.add(const Duration(seconds: 4));
    await follower.synchronize();

    expect(follower.visibleRiderIds, isNot(contains('leader')));
    expect(
      follower.presence.map((entry) => entry.riderId),
      isNot(contains('leader')),
    );
  });
}

class _Device {
  _Device(this.session, this.controller, this._clock);

  final RideSession session;
  final PreStartPresenceController controller;
  final DateTime Function() _clock;

  Future<void> start() => controller.start(session);

  Future<void> synchronize() => controller.synchronizeNow();

  Future<void> publish(double latitude) async {
    controller.updateLocalPosition(
      _location(
        session.localRiderId,
        session.displayName,
        latitude,
        _clock(),
        role: session.role,
      ),
    );
    await controller.synchronizeNow();
  }

  List<LiveRiderPresence> get presence => controller.presenceAt(_clock());

  Iterable<String> get visibleRiderIds =>
      controller.locations.map((location) => location.riderId);

  Iterable<String> get rosterIds =>
      controller.roster.map((member) => member.riderId);

  RiderLocation? positionFor(String riderId) => controller.locations
      .where((location) => location.riderId == riderId)
      .firstOrNull;

  PresenceFreshness? freshnessFor(String riderId) => presence
      .where((entry) => entry.riderId == riderId)
      .firstOrNull
      ?.freshness;
}

/// A shared relay both devices talk to, implementing the same rules as the
/// FastAPI service: replace-only positions, a TTL, a phase, and a roster derived
/// from membership rather than from any caller's cursor.
class _FakeRelay {
  _FakeRelay(this._clock);

  final DateTime Function() _clock;
  final Map<String, _StoredPosition> _positions = {};
  final List<PresenceRosterEntry> _members = [];
  Set<String> capabilities = RelayProtocolCapabilities.current;
  Duration ttl = const Duration(seconds: 45);
  RidePresencePhase phase = RidePresencePhase.open;
  bool reportPhase = true;
  bool reportMembers = true;
  bool offline = false;
  bool unauthorized = false;

  PreStartPresenceApi apiFor(String riderId) => _FakeRelayApi(this, riderId);

  void startRide() => phase = RidePresencePhase.started;

  void join(String riderId, String displayName, String role) {
    _members
      ..removeWhere((member) => member.riderId == riderId)
      ..add(
        PresenceRosterEntry(
          riderId: riderId,
          displayName: displayName,
          role: role,
          joinedAt: _clock(),
        ),
      );
  }

  void leave(String riderId) {
    for (var index = 0; index < _members.length; index += 1) {
      final member = _members[index];
      if (member.riderId != riderId) continue;
      _members[index] = PresenceRosterEntry(
        riderId: member.riderId,
        displayName: member.displayName,
        role: member.role,
        joinedAt: member.joinedAt,
        left: true,
      );
    }
  }

  void publish(
    String riderId,
    String displayName,
    double latitude,
    DateTime recordedAt, {
    bool livePresence = true,
  }) {
    _positions[riderId] = _StoredPosition(
      location: _location(riderId, displayName, latitude, recordedAt),
      expiresAt: _clock().add(ttl),
      livePresence: livePresence,
    );
  }

  PreStartPresenceResult handle({
    required String riderId,
    required RiderLocation? position,
    required bool clear,
  }) {
    if (offline) {
      throw const InternetRelayException(
        'Live positions are temporarily unavailable.',
        retryable: true,
      );
    }
    if (unauthorized) {
      throw const InternetRelayException(
        'The ride service rejected this ride credential.',
        unauthorized: true,
      );
    }
    final servesLive = capabilities.contains(
      RelayProtocolCapabilities.livePresence,
    );
    if (!servesLive &&
        !capabilities.contains(RelayProtocolCapabilities.preStartPresence)) {
      throw const InternetRelayException(
        'This ride service does not support live rider positions yet.',
        code: 'feature_unsupported',
      );
    }
    final now = _clock();
    _positions.removeWhere((_, stored) => !stored.expiresAt.isAfter(now));
    if (phase == RidePresencePhase.ended) {
      _positions.clear();
    } else if (clear) {
      _positions.remove(riderId);
    } else if (position != null) {
      _positions[riderId] = _StoredPosition(
        location: position,
        expiresAt: now.add(ttl),
        livePresence: servesLive,
      );
    }
    final visible = phase == RidePresencePhase.started && !servesLive
        ? const <_StoredPosition>[]
        : _positions.values.toList(growable: false);
    return PreStartPresenceResult(
      locations: [for (final stored in visible) stored.location],
      ttl: ttl,
      phase: reportPhase ? phase : RidePresencePhase.unknown,
      roster: reportMembers && servesLive
          ? List.of(_members)
          : const <PresenceRosterEntry>[],
      legacyPeerRiderIds: {
        for (final stored in visible)
          if (!stored.livePresence) stored.location.riderId,
      },
      livePresenceServed: servesLive,
    );
  }
}

class _StoredPosition {
  const _StoredPosition({
    required this.location,
    required this.expiresAt,
    required this.livePresence,
  });

  final RiderLocation location;
  final DateTime expiresAt;
  final bool livePresence;
}

class _FakeRelayApi implements PreStartPresenceApi {
  _FakeRelayApi(this._relay, this._riderId);

  final _FakeRelay _relay;
  final String _riderId;

  @override
  InternetRelayConfiguration get configuration =>
      InternetRelayConfiguration(baseUri: Uri.parse('https://relay.example'));

  @override
  Future<PreStartPresenceResult> synchronizePreStartPresence({
    required RideSession session,
    required RiderLocation? position,
    required bool clear,
  }) async =>
      _relay.handle(riderId: _riderId, position: position, clear: clear);

  @override
  void close() {}
}

class _FakeNearbyGateway implements RelayPresenceGateway {
  final _updates = StreamController<RelayPresenceUpdate>.broadcast();
  final List<({RiderLocation? position, bool clear, Duration ttl})> published =
      [];

  @override
  Stream<RelayPresenceUpdate> get presenceUpdates => _updates.stream;

  void emit(RelayPresenceUpdate update) => _updates.add(update);

  @override
  Future<void> publishPresence(
    RiderLocation? position, {
    bool clear = false,
    Duration ttl = const Duration(seconds: 45),
  }) async {
    published.add((position: position, clear: clear, ttl: ttl));
  }

  Future<void> close() => _updates.close();
}

RideSession _session(String riderId, String name, RideRole role) => RideSession(
  rideId: 'ride-live-presence',
  rideCode: '123456',
  inviteSecret: '0123456789abcdef0123456789abcdef',
  joinToken: 'test-join-token-0123456789',
  localRiderId: riderId,
  displayName: name,
  role: role,
  joinedAt: DateTime.utc(2026, 7, 25, 9),
);

RiderLocation _location(
  String riderId,
  String displayName,
  double latitude,
  DateTime recordedAt, {
  RideRole role = RideRole.rider,
}) => RiderLocation(
  riderId: riderId,
  displayName: displayName,
  role: role,
  sample: LocationSample(
    position: GeoPoint(latitude: latitude, longitude: -2.4),
    recordedAt: recordedAt,
    accuracyMeters: 5,
  ),
  receivedAt: recordedAt,
);

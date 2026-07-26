import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ride_relay/controllers/pre_start_presence_controller.dart';
import 'package:ride_relay/domain/geo_point.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:ride_relay/domain/rider_location.dart';
import 'package:ride_relay/internet/internet_relay_client.dart';
import 'package:ride_relay/relay/live_presence.dart';
import 'package:ride_relay/services/ride_membership.dart';

/// Two simulated devices whose clocks do **not** agree, sharing one relay, over
/// the real presence client so the response decoder is in the loop.
///
/// Issue #132 requires freshness to be judged on a clock both devices agree on.
/// The relay stamps every position's arrival and reports its own current time,
/// so a peer's position is aged on that one clock. Judging it against this
/// phone's clock minus the *peer's* timestamp measured the difference between two
/// clocks and aged out a rider who was reporting every few seconds.
void main() {
  late _Relay relay;

  setUp(() => relay = _Relay());

  _Device device(
    String riderId,
    String name, {
    RideRole role = RideRole.rider,
    Duration clockOffset = Duration.zero,
  }) {
    final device = _Device(riderId, name, role, clockOffset, relay);
    addTearDown(device.controller.close);
    return device;
  }

  test(
    "a peer whose clock is behind stays live, and is named rather than aged out",
    () async {
      final leader = device('leader', 'Lead', role: RideRole.lead);
      final follower = device(
        'follower',
        'Alex',
        clockOffset: const Duration(minutes: -4),
      );
      relay.join('leader', 'Lead', 'lead');
      relay.join('follower', 'Alex', 'rider');
      relay.startRide();
      await leader.start();
      await follower.start();

      await follower.publish(51.3);
      relay.serverNow = relay.serverNow.add(const Duration(seconds: 4));
      await leader.synchronize();

      final seen = leader.presenceFor('follower')!;
      // Four minutes of clock difference is not four minutes of age.
      expect(seen.freshness, PresenceFreshness.live);
      expect(seen.clockBasis, PresenceClockBasis.sharedRelayClock);
      expect(seen.age, lessThan(const Duration(seconds: 30)));
      expect(seen.location, isNotNull);

      // The disagreement is stated in words, with the rider named.
      final limitation = leader.controller.limitations.singleWhere(
        (entry) => entry.kind == PresenceLimitationKind.riderClockUntrusted,
      );
      expect(limitation.riderId, 'follower');
      expect(limitation.message, contains('Alex'));
      expect(limitation.message, contains('behind'));

      // And the rider is active in the roster, not "inactive · location stale".
      final participant = leader.participantFor('follower');
      expect(participant.state, RideMembershipState.active);
      expect(participant.positionFreshness, PresenceFreshness.live);
    },
  );

  test(
    'a peer whose clock is ahead is judged on the relay clock too',
    () async {
      final leader = device('leader', 'Lead', role: RideRole.lead);
      final follower = device(
        'follower',
        'Alex',
        clockOffset: const Duration(minutes: 3),
      );
      relay.join('leader', 'Lead', 'lead');
      relay.join('follower', 'Alex', 'rider');
      relay.startRide();
      await leader.start();
      await follower.start();

      await follower.publish(51.3);
      await leader.synchronize();

      final seen = leader.presenceFor('follower')!;
      expect(seen.freshness, PresenceFreshness.live);
      expect(
        leader.controller.limitations
            .where(
              (entry) =>
                  entry.kind == PresenceLimitationKind.riderClockUntrusted,
            )
            .map((entry) => entry.message)
            .single,
        contains('ahead of'),
      );
    },
  );

  test(
    'a device whose own clock runs ahead of the relay still sees everyone',
    () async {
      // The failure this reproduces: every position the relay returned looked
      // expired against this phone's clock, so the whole reply — positions and
      // roster alike — was discarded on every poll, and the channel reported
      // "the ride service cannot be reached" while it was answering perfectly.
      final leader = device(
        'leader',
        'Lead',
        role: RideRole.lead,
        clockOffset: const Duration(seconds: 90),
      );
      final follower = device('follower', 'Alex');
      relay.join('leader', 'Lead', 'lead');
      relay.join('follower', 'Alex', 'rider');
      relay.startRide();
      await follower.start();
      await follower.publish(51.3);
      await leader.start();

      expect(leader.controller.availability, PresenceAvailability.live);
      expect(leader.controller.unavailableReason, isNull);
      expect(leader.rosterIds, containsAll(['leader', 'follower']));
      expect(leader.presenceFor('follower')!.location, isNotNull);
      expect(leader.presenceFor('follower')!.freshness, PresenceFreshness.live);
    },
  );

  test('one unreadable position does not hide the others', () async {
    final leader = device('leader', 'Lead', role: RideRole.lead);
    final follower = device('follower', 'Alex');
    relay.join('follower', 'Alex', 'rider');
    await follower.start();
    await follower.publish(51.3);
    relay.injectUnreadablePosition = true;

    await leader.start();

    expect(leader.controller.availability, PresenceAvailability.live);
    expect(leader.presenceFor('follower')!.location, isNotNull);
    final limitation = leader.controller.limitations.singleWhere(
      (entry) => entry.kind == PresenceLimitationKind.positionsUnreadable,
    );
    expect(limitation.message, contains('could not be read'));
  });

  test('the relay clock offset is measured and reported', () async {
    final leader = device(
      'leader',
      'Lead',
      role: RideRole.lead,
      clockOffset: const Duration(seconds: -45),
    );
    await leader.start();

    // The relay is 45 seconds ahead of this phone.
    expect(leader.controller.relayClockOffset.inSeconds, 45);
  });

  test(
    'a position stops being retained on the relay clock, not the peer\'s',
    () async {
      final leader = device('leader', 'Lead', role: RideRole.lead);
      final follower = device(
        'follower',
        'Alex',
        clockOffset: const Duration(minutes: -10),
      );
      relay.join('follower', 'Alex', 'rider');
      await follower.start();
      await follower.publish(51.3);
      await leader.start();

      // Ten minutes of clock error is well past the five-minute retention window,
      // yet the position arrived seconds ago on the relay's clock.
      expect(leader.presenceFor('follower')!.location, isNotNull);
      expect(leader.controller.internetLocations, isNotEmpty);
    },
  );
}

class _Device {
  _Device(
    this.riderId,
    this.displayName,
    this.role,
    this.clockOffset,
    this.relay,
  ) : controller = PreStartPresenceController(
        HttpPreStartPresenceClient(
          configuration: InternetRelayConfiguration(
            baseUri: Uri.parse('https://relay.example/api'),
          ),
          client: MockClient(relay.handle),
          clock: () => relay.serverNow.add(clockOffset),
        ),
        pollInterval: const Duration(days: 1),
        clock: () => relay.serverNow.add(clockOffset),
      );

  final String riderId;
  final String displayName;
  final RideRole role;

  /// This phone's clock minus the relay's.
  final Duration clockOffset;
  final _Relay relay;
  final PreStartPresenceController controller;

  DateTime get now => relay.serverNow.add(clockOffset);

  RideSession get session => RideSession(
    rideId: 'ride-clock-skew',
    rideCode: '123456',
    inviteSecret: '0123456789abcdef0123456789abcdef',
    joinToken: 'test-join-token-0123456789',
    localRiderId: riderId,
    displayName: displayName,
    role: role,
    joinedAt: now,
  );

  late final RideSession _session = session;

  Future<void> start() => controller.start(_session);

  Future<void> synchronize() => controller.synchronizeNow();

  Future<void> publish(double latitude) async {
    controller.updateLocalPosition(
      RiderLocation(
        riderId: riderId,
        displayName: displayName,
        role: role,
        sample: LocationSample(
          position: GeoPoint(latitude: latitude, longitude: -2.4),
          recordedAt: now,
          accuracyMeters: 5,
        ),
        receivedAt: now,
      ),
    );
    await controller.synchronizeNow();
  }

  LiveRiderPresence? presenceFor(String riderId) => controller
      .presenceAt(now)
      .where((entry) => entry.riderId == riderId)
      .firstOrNull;

  Iterable<String> get rosterIds =>
      controller.roster.map((member) => member.riderId);

  /// The roster row this device would show, from the one reconciled model.
  RideParticipant participantFor(String riderId) =>
      const RideMembershipReducer()
          .fromEvents(
            rideId: _session.rideId,
            inviteSecret: _session.inviteSecret,
            events: const [],
            now: now,
            localRiderId: _session.localRiderId,
            localDisplayName: _session.displayName,
            localRole: _session.role,
            localJoinedAt: _session.joinedAt,
            localMotorcycleStyle: _session.motorcycleStyle,
            localRiderColor: _session.riderColor,
            rideStartedAt: now.subtract(const Duration(minutes: 30)),
            livePresence: controller.presenceAt(now),
          )
          .firstWhere((participant) => participant.riderId == riderId);
}

/// A fake relay that stamps arrivals and reports its own clock, exactly as
/// `apps/server` does.
class _Relay {
  DateTime serverNow = DateTime.utc(2026, 7, 26, 12);
  Duration ttl = const Duration(seconds: 45);
  bool started = false;
  bool injectUnreadablePosition = false;
  final Map<String, Map<String, Object?>> _positions = {};
  final List<Map<String, Object?>> _members = [];

  void startRide() => started = true;

  void join(String riderId, String displayName, String role) => _members.add({
    'riderId': riderId,
    'displayName': displayName,
    'role': role,
    'joinedAt': serverNow.toIso8601String(),
    'left': false,
  });

  Future<http.Response> handle(http.Request request) async {
    if (request.url.path.endsWith('/v1/compatibility')) {
      return http.Response(
        jsonEncode({
          'serverProtocol': 1,
          'minimumClientProtocol': 1,
          'maximumClientProtocol': 1,
          'capabilities': RelayProtocolCapabilities.current.toList(),
          'requiredCapabilities': <String>[],
          'cacheSeconds': 300,
          'updateUrls': {'default': 'https://tailendcharlie.app'},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    final body = jsonDecode(request.body) as Map<String, Object?>;
    final riderId = body['deviceId']! as String;
    final position = body['position'];
    _positions.removeWhere(
      (_, row) =>
          !DateTime.parse(row['expiresAt']! as String).isAfter(serverNow),
    );
    if (body['clear'] == true) {
      _positions.remove(riderId);
    } else if (position is Map) {
      _positions[riderId] = {
        ...Map<String, Object?>.from(position),
        'riderId': riderId,
        // The relay's own stamps, on the relay's own clock.
        'receivedAt': serverNow.toIso8601String(),
        'expiresAt': serverNow.add(ttl).toIso8601String(),
        'livePresence': true,
        'clientProtocol': 1,
      };
    }
    return http.Response(
      jsonEncode({
        'protocolVersion': 1,
        'ttlSeconds': ttl.inSeconds,
        'phase': started ? 'started' : 'open',
        'members': _members,
        'serverTime': serverNow.toIso8601String(),
        'positions': [
          ..._positions.values,
          if (injectUnreadablePosition) {'riderId': 'broken'},
        ],
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

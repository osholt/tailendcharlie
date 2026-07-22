import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/domain/imported_route.dart';
import 'package:ride_relay/domain/ride_event.dart';
import 'package:ride_relay/services/ride_event_authenticator.dart';
import 'package:ride_relay/services/ride_route_reducer.dart';

void main() {
  const secret = '0123456789abcdef0123456789abcdef';
  final start = DateTime.utc(2026, 7, 22, 10);

  test('a complete leader revision converges from shuffled chunks', () {
    final encoded = const RideRouteEncoder(
      maximumChunkCharacters: 24,
    ).encode(_route('Coast route'));
    final events = <RideEvent>[
      _event(
        id: 'created',
        deviceId: 'leader',
        type: RideEventType.rideCreated,
        createdAt: start,
        payload: const {'displayName': 'Lead', 'role': 'lead'},
        secret: secret,
      ),
      for (var index = 0; index < encoded.chunks.length; index += 1)
        _event(
          id: 'chunk-${index.toString().padLeft(3, '0')}',
          deviceId: 'leader',
          type: RideEventType.routeRevisionChunk,
          createdAt: start.add(const Duration(minutes: 1)),
          payload: {
            'revisionId': 'revision-a',
            'revisionNumber': 1,
            'leaderRiderId': 'leader',
            'index': index,
            'data': encoded.chunks[index],
          },
          secret: secret,
        ),
      _event(
        id: 'manifest',
        deviceId: 'leader',
        type: RideEventType.routeRevisionPublished,
        createdAt: start.add(const Duration(minutes: 2)),
        payload: {
          'revisionId': 'revision-a',
          'revisionNumber': 1,
          'leaderRiderId': 'leader',
          'chunkCount': encoded.chunks.length,
          'compressedBytes': encoded.compressedBytes,
          'sha256': encoded.sha256Digest,
        },
        secret: secret,
      ),
    ];

    final state = const RideRouteReducer().fromEvents(
      rideId: 'ride-a',
      inviteSecret: secret,
      events: events.reversed,
    );

    expect(state.hasDecision, isTrue);
    expect(state.revisionId, 'revision-a');
    expect(state.route?.name, 'Coast route');
    expect(state.route?.pathPointCount, 3);
  });

  test('incomplete revisions do not replace the last complete route', () {
    final complete = _publishedRevision(
      route: _route('Original'),
      revisionId: 'original',
      revisionNumber: 1,
      start: start,
      secret: secret,
    );
    final incomplete = _publishedRevision(
      route: _route('Incomplete'),
      revisionId: 'incomplete',
      revisionNumber: 2,
      start: start.add(const Duration(minutes: 5)),
      secret: secret,
    );
    incomplete.removeWhere(
      (event) =>
          event.type == RideEventType.routeRevisionChunk &&
          event.payload['index'] == 0,
    );

    final state = const RideRouteReducer().fromEvents(
      rideId: 'ride-a',
      inviteSecret: secret,
      events: [
        _event(
          id: 'created',
          deviceId: 'leader',
          type: RideEventType.rideCreated,
          createdAt: start.subtract(const Duration(minutes: 1)),
          payload: const {'displayName': 'Lead', 'role': 'lead'},
          secret: secret,
        ),
        ...complete,
        ...incomplete,
      ],
    );

    expect(state.route?.name, 'Original');
    expect(state.revisionId, 'original');
  });

  test('a signed leader clear deterministically removes the route', () {
    final events = [
      _event(
        id: 'created',
        deviceId: 'leader',
        type: RideEventType.rideCreated,
        createdAt: start,
        payload: const {'displayName': 'Lead', 'role': 'lead'},
        secret: secret,
      ),
      ..._publishedRevision(
        route: _route('Original'),
        revisionId: 'original',
        revisionNumber: 1,
        start: start.add(const Duration(minutes: 1)),
        secret: secret,
      ),
      _event(
        id: 'clear',
        deviceId: 'leader',
        type: RideEventType.routeCleared,
        createdAt: start.add(const Duration(minutes: 4)),
        payload: const {
          'revisionId': 'clear-a',
          'revisionNumber': 2,
          'leaderRiderId': 'leader',
        },
        secret: secret,
      ),
    ];

    final state = const RideRouteReducer().fromEvents(
      rideId: 'ride-a',
      inviteSecret: secret,
      events: events,
    );

    expect(state.hasDecision, isTrue);
    expect(state.route, isNull);
    expect(state.revisionId, 'clear-a');
  });

  test('a later signed leader revision wins after offline role handover', () {
    final events = [
      _event(
        id: 'created',
        deviceId: 'leader',
        type: RideEventType.rideCreated,
        createdAt: start,
        payload: const {'displayName': 'Lead', 'role': 'lead'},
        secret: secret,
      ),
      ..._publishedRevision(
        route: _route('Original'),
        revisionId: 'original',
        revisionNumber: 1,
        start: start.add(const Duration(minutes: 1)),
        secret: secret,
      ),
      _event(
        id: 'new-leader-joined',
        deviceId: 'new-leader',
        type: RideEventType.riderJoined,
        createdAt: start.add(const Duration(minutes: 3)),
        payload: const {'displayName': 'Alex', 'role': 'rider'},
        secret: secret,
      ),
      _event(
        id: 'new-leader-promoted',
        deviceId: 'new-leader',
        type: RideEventType.roleChanged,
        createdAt: start.add(const Duration(minutes: 4)),
        payload: const {'role': 'lead'},
        secret: secret,
      ),
      ..._publishedRevision(
        route: _route('Replacement'),
        revisionId: 'replacement',
        revisionNumber: 2,
        start: start.add(const Duration(minutes: 5)),
        secret: secret,
        deviceId: 'new-leader',
      ),
    ];

    final state = const RideRouteReducer().fromEvents(
      rideId: 'ride-a',
      inviteSecret: secret,
      events: events.reversed,
    );

    expect(state.route?.name, 'Replacement');
    expect(state.revisionNumber, 2);
    expect(state.changedByRiderId, 'new-leader');
  });

  test('a late stale revision cannot roll back a newer route version', () {
    final events = [
      _event(
        id: 'created',
        deviceId: 'leader',
        type: RideEventType.rideCreated,
        createdAt: start,
        payload: const {'displayName': 'Lead', 'role': 'lead'},
        secret: secret,
      ),
      ..._publishedRevision(
        route: _route('Current'),
        revisionId: 'current',
        revisionNumber: 3,
        start: start.add(const Duration(minutes: 1)),
        secret: secret,
      ),
      ..._publishedRevision(
        route: _route('Stale'),
        revisionId: 'stale',
        revisionNumber: 2,
        start: start.add(const Duration(minutes: 5)),
        secret: secret,
      ),
    ];

    final state = const RideRouteReducer().fromEvents(
      rideId: 'ride-a',
      inviteSecret: secret,
      events: events,
    );

    expect(state.route?.name, 'Current');
    expect(state.revisionNumber, 3);
  });
}

List<RideEvent> _publishedRevision({
  required ImportedRoute route,
  required String revisionId,
  required int revisionNumber,
  required DateTime start,
  required String secret,
  String deviceId = 'leader',
}) {
  final encoded = const RideRouteEncoder(
    maximumChunkCharacters: 60,
  ).encode(route);
  return [
    for (var index = 0; index < encoded.chunks.length; index += 1)
      _event(
        id: '$revisionId-chunk-$index',
        deviceId: deviceId,
        type: RideEventType.routeRevisionChunk,
        createdAt: start,
        payload: {
          'revisionId': revisionId,
          'revisionNumber': revisionNumber,
          'leaderRiderId': deviceId,
          'index': index,
          'data': encoded.chunks[index],
        },
        secret: secret,
      ),
    _event(
      id: '$revisionId-manifest',
      deviceId: deviceId,
      type: RideEventType.routeRevisionPublished,
      createdAt: start.add(const Duration(minutes: 1)),
      payload: {
        'revisionId': revisionId,
        'revisionNumber': revisionNumber,
        'leaderRiderId': deviceId,
        'chunkCount': encoded.chunks.length,
        'compressedBytes': encoded.compressedBytes,
        'sha256': encoded.sha256Digest,
      },
      secret: secret,
    ),
  ];
}

ImportedRoute _route(String name) => ImportedRoute(
  id: 'route-${name.toLowerCase()}',
  name: name,
  importedAt: DateTime.utc(2026, 7, 22),
  sourceFileName: 'route.gpx',
  paths: const [
    RoutePath(
      kind: RoutePathKind.track,
      points: [
        GeoPoint(latitude: 51.45, longitude: -2.59),
        GeoPoint(latitude: 51.46, longitude: -2.58),
        GeoPoint(latitude: 51.47, longitude: -2.57),
      ],
    ),
  ],
  waypoints: const [],
);

RideEvent _event({
  required String id,
  required String deviceId,
  required RideEventType type,
  required DateTime createdAt,
  required Map<String, Object?> payload,
  required String secret,
}) {
  final unsigned = RideEvent(
    id: id,
    rideId: 'ride-a',
    deviceId: deviceId,
    type: type,
    priority: EventPriority.important,
    createdAt: createdAt,
    payload: payload,
    signature: '',
  );
  return RideEvent(
    id: id,
    rideId: 'ride-a',
    deviceId: deviceId,
    type: type,
    priority: EventPriority.important,
    createdAt: createdAt,
    payload: payload,
    signature: RideEventAuthenticator.sign(unsigned, secret),
  );
}

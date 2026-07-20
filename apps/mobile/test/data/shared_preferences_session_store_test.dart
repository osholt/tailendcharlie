import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ride_relay/data/shared_preferences_session_store.dart';
import 'package:ride_relay/domain/ride_role.dart';
import 'package:ride_relay/domain/ride_secret_store.dart';
import 'package:ride_relay/domain/ride_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('stores invitation secrets outside SharedPreferences', () async {
    final secrets = _MemorySecretStore();
    final store = SharedPreferencesSessionStore(secretStore: secrets);
    final session = _session();

    await store.save(session);

    final preferences = await SharedPreferences.getInstance();
    final metadata = preferences.getString('active_ride_session_v1')!;
    expect(metadata, isNot(contains(session.inviteSecret)));
    expect(jsonDecode(metadata), isNot(contains('inviteSecret')));
    expect(await store.load(), _matches(session));

    await store.clear();
    expect(await secrets.read(session.rideId), isNull);
    expect(await store.load(), isNull);
  });

  test('migrates a legacy plaintext session on first load', () async {
    final session = _session();
    SharedPreferences.setMockInitialValues({
      'active_ride_session_v1': jsonEncode(session.toJson()),
    });
    final secrets = _MemorySecretStore();
    final store = SharedPreferencesSessionStore(secretStore: secrets);

    expect(await store.load(), _matches(session));
    expect(await secrets.read(session.rideId), session.inviteSecret);
    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString('active_ride_session_v1'),
      isNot(contains(session.inviteSecret)),
    );
  });

  test('preserves an intentional code-only local ride', () async {
    final store = SharedPreferencesSessionStore(
      secretStore: _MemorySecretStore(),
    );
    final localOnly = RideSession(
      rideId: 'pending-ABC234',
      rideCode: 'ABC234',
      inviteSecret: '',
      joinToken: 'test-join-token-0123456789',
      localRiderId: 'rider-1',
      displayName: 'Oliver',
      role: RideRole.rider,
      joinedAt: DateTime.utc(2026, 7, 16, 12),
    );

    await store.save(localOnly);

    expect(await store.load(), _matches(localOnly));
  });

  test(
    'always sanitizes legacy plaintext even when secure copy exists',
    () async {
      final session = _session();
      SharedPreferences.setMockInitialValues({
        'active_ride_session_v1': jsonEncode(session.toJson()),
      });
      final secrets = _MemorySecretStore();
      await secrets.write(session.rideId, session.inviteSecret);
      final store = SharedPreferencesSessionStore(secretStore: secrets);

      expect(await store.load(), _matches(session));
      final preferences = await SharedPreferences.getInstance();
      expect(
        preferences.getString('active_ride_session_v1'),
        isNot(contains(session.inviteSecret)),
      );
    },
  );
}

RideSession _session() => RideSession(
  rideId: 'ride-1',
  rideCode: 'ABC234',
  inviteSecret: '0123456789abcdef0123456789abcdef',
  joinToken: 'test-join-token-0123456789',
  localRiderId: 'rider-1',
  displayName: 'Oliver',
  role: RideRole.lead,
  joinedAt: DateTime.utc(2026, 7, 16, 12),
);

Matcher _matches(RideSession expected) => isA<RideSession>()
    .having((value) => value.rideId, 'rideId', expected.rideId)
    .having(
      (value) => value.inviteSecret,
      'inviteSecret',
      expected.inviteSecret,
    );

class _MemorySecretStore implements RideSecretStore {
  final _values = <String, String>{};

  @override
  Future<void> delete(String rideId) async => _values.remove(rideId);

  @override
  Future<String?> read(String rideId) async => _values[rideId];

  @override
  Future<void> write(String rideId, String secret) async {
    _values[rideId] = secret;
  }
}
